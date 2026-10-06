#!/usr/bin/env python3
"""Backend test suite. Runs against a real HTTPS server over a real socket.

    python3 backend/tests/test_backend.py

Nothing here calls the service object directly: every assertion goes through the
network, so what is being tested is what the iOS client can actually reach.
Exits 0 only when every test passes.
"""
import json
import os
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "backend"))

import db  # noqa: E402
import server as server_module  # noqa: E402

PORT = int(os.environ.get("GREENCORD_TEST_PORT", "8471"))
BASE = f"https://127.0.0.1:{PORT}"
CERT = os.path.join(ROOT, "build", "certs", "server.crt")
KEY = os.path.join(ROOT, "build", "certs", "server.key")

# The prototype's certificate is self-signed, so the test client trusts that
# one certificate explicitly rather than turning verification off.
TLS = ssl.create_default_context(cafile=CERT)
TLS.check_hostname = False

results = []
_state = {}


def test(name):
    def wrap(fn):
        results.append((name, fn))
        return fn
    return wrap


class ApiError(Exception):
    def __init__(self, status, body):
        super().__init__(f"HTTP {status}: {body}")
        self.status = status
        self.body = body


def call(method, path, token=None, payload=None, raw=False):
    url = BASE + path
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    if data:
        request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, context=TLS, timeout=20) as response:
            body = response.read().decode()
            return body if raw else json.loads(body)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        try:
            body = json.loads(body)
        except ValueError:
            pass
        raise ApiError(exc.code, body)


def expect_status(status, method, path, **kwargs):
    try:
        result = call(method, path, **kwargs)
    except ApiError as exc:
        assert exc.status == status, f"expected {status}, got {exc.status}: {exc.body}"
        return exc.body
    raise AssertionError(f"expected HTTP {status}, got 200 with {result}")


# --------------------------------------------------------------------- setup


def counselor_token():
    return _state["counselor_token"]


def make_codes(grade, count=1, last_name="Testcase", first_name=None,
               expires_in_days=None):
    """Codes for named students, which is the only way to issue one."""
    students = [
        {
            "firstName": first_name or f"Student{index + 1}",
            "lastName": last_name,
            "grade": grade,
        }
        for index in range(count)
    ]
    payload = {"students": students}
    if expires_in_days is not None:
        payload["expiresInDays"] = expires_in_days
    issued = call("POST", "/invite-codes", token=counselor_token(), payload=payload)["codes"]
    return [entry["code"] for entry in issued]


def make_student(grade, last_name, username, password="password123"):
    code = make_codes(grade, last_name=last_name, first_name=username.title())[0]
    result = call("POST", "/auth/redeem", payload={
        "code": code, "username": username, "password": password,
    })
    return result["token"], result["account"]


def make_entry(token, hours=5.0, category="community", organization="Food Bank",
               date="2026-09-01"):
    return call("POST", "/entries", token=token, payload={
        "serviceDate": date, "hours": hours, "category": category,
        "organization": organization, "description": "Sorted donations",
        "verifierName": "Site Supervisor", "verifierContact": "supervisor@example.org",
    })["entry"]


def approve(entry_id, note="Looks good"):
    return call("POST", f"/entries/{entry_id}/decision", token=counselor_token(),
                payload={"action": "approve", "note": note})["entry"]


# --------------------------------------------------------------------- tests


@test("B12 plain HTTP is refused by the HTTPS listener")
def t_http_refused():
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=10)
    except Exception as exc:  # noqa: BLE001 - any failure to complete is the point
        assert not isinstance(exc, urllib.error.HTTPError) or exc.code >= 400, exc
        return
    raise AssertionError("plain HTTP request completed; it must not")


@test("B12 HTTPS health check answers")
def t_health():
    assert call("GET", "/health")["ok"] is True


@test("B5 counselor exists and was provisioned off the API")
def t_counselor_provisioned():
    me = call("GET", "/me", token=counselor_token())["account"]
    assert me["role"] == "admin", me
    assert me["grade"] is None, me


@test("B5 no endpoint can create a counselor")
def t_no_counselor_endpoint():
    # The only account-creating path is redeem, and it hard-codes 'student'.
    code = make_codes(11, last_name="Probe", first_name="Role")[0]
    result = call("POST", "/auth/redeem", payload={
        "code": code, "username": "roleprobe", "password": "password123",
        "role": "counselor",
    })
    assert result["account"]["role"] == "student", result["account"]


@test("B2 sign-up with no code fails")
def t_redeem_no_code():
    body = expect_status(400, "POST", "/auth/redeem", payload={
        "username": "nocode", "password": "password123",
    })
    assert body["code"] == "code_missing", body


@test("B2 sign-up with an unknown code fails")
def t_redeem_unknown():
    body = expect_status(400, "POST", "/auth/redeem", payload={
        "code": "ZZZZZZZZ", "username": "badcode", "password": "password123",
    })
    assert body["code"] == "code_unknown", body


@test("B2 sign-up with an expired code fails")
def t_redeem_expired():
    codes = make_codes(9, last_name="Late", first_name="Late", expires_in_days=30)
    _state["service"].conn.execute(
        "UPDATE invite_codes SET expires_at = ? WHERE code = ?",
        (time.time() - 3600, codes[0]),
    )
    body = expect_status(400, "POST", "/auth/redeem", payload={
        "code": codes[0], "username": "latecode", "password": "password123",
    })
    assert body["code"] == "code_expired", body


@test("B2 a code works exactly once and is then marked redeemed")
def t_redeem_once():
    code = make_codes(10, last_name="Once", first_name="First")[0]
    call("POST", "/auth/redeem", payload={
        "code": code, "username": "firstuse", "password": "password123",
    })
    body = expect_status(400, "POST", "/auth/redeem", payload={
        "code": code, "username": "seconduse", "password": "password123",
    })
    assert body["code"] == "code_used", body

    codes = call("GET", "/invite-codes", token=counselor_token())["codes"]
    entry = next(c for c in codes if c["code"] == code)
    assert entry["state"] == "redeemed", entry


@test("B2 concurrent double redemption yields exactly one account")
def t_redeem_race():
    code = make_codes(12, last_name="Racer", first_name="Racer")[0]
    outcomes = []

    def attempt(index):
        try:
            call("POST", "/auth/redeem", payload={
                "code": code, "username": f"racer{index}", "password": "password123",
            })
            outcomes.append(("ok", index))
        except ApiError as exc:
            outcomes.append(("fail", exc.status))

    threads = [threading.Thread(target=attempt, args=(i,)) for i in range(6)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    successes = [o for o in outcomes if o[0] == "ok"]
    assert len(successes) == 1, f"expected exactly 1 success, got {outcomes}"
    accounts = _state["service"].conn.execute(
        "SELECT COUNT(*) AS n FROM accounts WHERE username LIKE 'racer%'"
    ).fetchone()["n"]
    assert accounts == 1, f"{accounts} accounts created from one code"


@test("B3 batch codes are unique and use the transcribable alphabet")
def t_code_alphabet():
    codes = make_codes(9, count=40)
    assert len(codes) == 40, len(codes)
    assert len(set(codes)) == 40, "codes are not unique"
    for code in codes:
        assert len(code) == db.CODE_LENGTH, code
        for character in code:
            assert character in db.CODE_ALPHABET, f"{code} contains {character!r}"
    for ambiguous in "01OIL":
        assert not any(ambiguous in c for c in codes), f"{ambiguous} appears in a code"


@test("B3 revoking a code blocks redemption")
def t_revoke():
    code = make_codes(11, last_name="Revoked", first_name="Revoked")[0]
    call("DELETE", f"/invite-codes/{code}", token=counselor_token())
    body = expect_status(400, "POST", "/auth/redeem", payload={
        "code": code, "username": "revokeduser", "password": "password123",
    })
    assert body["code"] == "code_revoked", body


@test("B3 the redeemed account's grade matches the code's grade")
def t_code_grade():
    for grade in (9, 10, 11, 12):
        _token, account = make_student(grade, f"Grade{grade}", f"gradecheck{grade}")
        assert account["grade"] == grade, account


@test("B3 the counselor sees outstanding vs redeemed counts")
def t_code_counts():
    summary = call("GET", "/invite-codes", token=counselor_token())
    assert summary["outstanding"] > 0, summary
    assert summary["redeemed"] > 0, summary


@test("B3 a code is issued for one named student and carries that name")
def t_code_is_named():
    issued = call("POST", "/invite-codes", token=counselor_token(), payload={
        "students": [{"firstName": "Named", "lastName": "Binding", "grade": 11}]
    })["codes"]
    assert len(issued) == 1, issued
    assert issued[0]["firstName"] == "Named", issued[0]
    assert issued[0]["lastName"] == "Binding", issued[0]
    assert issued[0]["grade"] == 11, issued[0]

    listed = call("GET", "/invite-codes", token=counselor_token())["codes"]
    row = next(c for c in listed if c["code"] == issued[0]["code"])
    assert (row["firstName"], row["lastName"]) == ("Named", "Binding"), row


@test("B3 bulk add issues one code per student, each with its own grade")
def t_bulk_add():
    cohort = [
        {"firstName": "Bulk", "lastName": "Nine", "grade": 9},
        {"firstName": "Bulk", "lastName": "Ten", "grade": 10},
        {"firstName": "Bulk", "lastName": "Eleven", "grade": 11},
        {"firstName": "Bulk", "lastName": "Twelve", "grade": 12},
    ]
    issued = call("POST", "/invite-codes", token=counselor_token(),
                  payload={"students": cohort})["codes"]
    assert len(issued) == 4, issued
    assert len({c["code"] for c in issued}) == 4, "codes are not unique"
    by_last = {c["lastName"]: c for c in issued}
    for student in cohort:
        assert by_last[student["lastName"]]["grade"] == student["grade"], by_last

    # A student missing a name or carrying a grade outside 9-12 is refused.
    expect_status(400, "POST", "/invite-codes", token=counselor_token(), payload={
        "students": [{"firstName": "", "lastName": "Nameless", "grade": 9}]
    })
    expect_status(400, "POST", "/invite-codes", token=counselor_token(), payload={
        "students": [{"firstName": "Out", "lastName": "Ofrange", "grade": 8}]
    })
    expect_status(400, "POST", "/invite-codes", token=counselor_token(),
                  payload={"students": []})


@test("B3 redeeming uses the name on the code, not a name the student types")
def t_redeem_name_comes_from_code():
    code = call("POST", "/invite-codes", token=counselor_token(), payload={
        "students": [{"firstName": "Assigned", "lastName": "Name", "grade": 10}]
    })["codes"][0]["code"]

    # The client sends a different name on purpose. It must be ignored.
    result = call("POST", "/auth/redeem", payload={
        "code": code, "username": "assignedname", "password": "password123",
        "displayName": "Someone Else", "lastName": "Elsewhere", "grade": 12,
    })
    account = result["account"]
    assert account["displayName"] == "Assigned Name", account
    assert account["lastName"] == "Name", account
    assert account["grade"] == 10, account


@test("B3 looking up a code tells the student who it is for")
def t_lookup_code():
    code = call("POST", "/invite-codes", token=counselor_token(), payload={
        "students": [{"firstName": "Lookup", "lastName": "Target", "grade": 12}]
    })["codes"][0]["code"]

    # Unauthenticated on purpose: it runs before an account exists.
    found = call("GET", f"/invite-codes/lookup?code={code}")
    assert found["firstName"] == "Lookup", found
    assert found["lastName"] == "Target", found
    assert found["grade"] == 12, found

    # Lower case is accepted, because a student reads it off a paper slip.
    assert call("GET", f"/invite-codes/lookup?code={code.lower()}")["lastName"] == "Target"

    expect_status(404, "GET", "/invite-codes/lookup?code=ZZZZZZZZ")
    expect_status(400, "GET", "/invite-codes/lookup?code=")

    # Once used, a lookup stops revealing the name.
    call("POST", "/auth/redeem", payload={
        "code": code, "username": "lookuptarget", "password": "password123",
    })
    body = expect_status(400, "GET", f"/invite-codes/lookup?code={code}")
    assert body["code"] == "code_used", body


@test("B10 the roster lists a student who has not signed up yet")
def t_roster_shows_pending_students():
    code = call("POST", "/invite-codes", token=counselor_token(), payload={
        "students": [{"firstName": "Notyet", "lastName": "Joined", "grade": 9}]
    })["codes"][0]["code"]

    rows = call("GET", "/roster", token=counselor_token())["students"]
    row = next(r for r in rows if r["lastName"] == "Joined")
    assert row["joined"] is False, row
    assert row["verifiedHours"] == 0.0, row
    assert row["grade"] == 9, row

    call("POST", "/auth/redeem", payload={
        "code": code, "username": "notyetjoined", "password": "password123",
    })

    rows = call("GET", "/roster", token=counselor_token())["students"]
    matching = [r for r in rows if r["lastName"] == "Joined"]
    assert len(matching) == 1, f"student listed twice after signing up: {matching}"
    assert matching[0]["joined"] is True, matching[0]


def invite_staff(first, last, role="manager"):
    """Admin issues a staff code; returns the code."""
    return call("POST", "/staff/invites", token=counselor_token(),
                payload={"firstName": first, "lastName": last, "role": role})["code"]


def make_staff(first, last, username, role="manager", password="password123"):
    code = invite_staff(first, last, role)
    result = call("POST", "/auth/redeem", payload={
        "code": code, "username": username, "password": password,
    })
    return result["token"], result["account"]


@test("B-staff an admin invites a manager, who sets their own password")
def t_invite_manager():
    code = invite_staff("Morgan", "Reyes", "manager")

    # The invited person sees who the code is for before committing to it.
    holder = call("GET", f"/invite-codes/lookup?code={code}")
    assert holder["role"] == "manager", holder
    assert holder["firstName"] == "Morgan", holder
    assert holder["grade"] is None, holder

    token, account = make_staff("Avery", "Stone", "avery.stone", "manager")
    assert account["role"] == "manager", account
    assert account["grade"] is None, account

    # The password was never known to the admin: it was set at redemption.
    call("POST", "/auth/login", payload={
        "username": "avery.stone", "password": "password123",
    })


@test("B-staff a manager can do the student-facing work")
def t_manager_can_work():
    token, _ = make_staff("Robin", "Patel", "robin.patel", "manager")

    # Review queue, roster and codes are all open to a manager.
    call("GET", "/roster", token=token)
    call("GET", "/invite-codes", token=token)

    # And they can add a student and approve hours.
    issued = call("POST", "/invite-codes", token=token, payload={
        "students": [{"firstName": "Managed", "lastName": "Student", "grade": 10}]
    })["codes"][0]
    student = call("POST", "/auth/redeem", payload={
        "code": issued["code"], "username": "managedstudent", "password": "password123",
    })
    entry = make_entry(student["token"], hours=4.0)
    call("POST", f"/entries/{entry['id']}/submit", token=student["token"])
    decided = call("POST", f"/entries/{entry['id']}/decision", token=token,
                   payload={"action": "approve", "note": "Approved by a manager"})
    assert decided["entry"]["status"] == "approved", decided

    progress = call("GET", "/progress", token=student["token"])["progress"]
    assert progress["verifiedHours"] == 4.0, progress


@test("B-staff a manager cannot create, change or remove staff")
def t_manager_cannot_manage_staff():
    token, _ = make_staff("Casey", "Nolan", "casey.nolan", "manager")
    _admin_token, target = make_staff("Target", "Person", "target.person", "manager")

    expect_status(403, "POST", "/staff/invites", token=token,
                  payload={"firstName": "Sneaky", "lastName": "Promotion", "role": "admin"})
    expect_status(403, "POST", f"/staff/{target['id']}/role", token=token,
                  payload={"role": "admin"})
    expect_status(403, "DELETE", f"/staff/{target['id']}", token=token)
    expect_status(403, "POST", "/password-resets", token=token,
                  payload={"accountId": target["id"]})

    # And still cannot promote themselves by any route.
    expect_status(403, "POST", "/me/role", token=token, payload={"role": "admin"})
    me = call("GET", "/me", token=token)["account"]
    assert me["role"] == "manager", me


@test("B-staff a student cannot reach staff management at all")
def t_student_cannot_manage_staff():
    token, _ = make_student(9, "Curious", "curious1")
    expect_status(403, "GET", "/staff", token=token)
    expect_status(403, "POST", "/staff/invites", token=token,
                  payload={"firstName": "No", "lastName": "Chance", "role": "admin"})


@test("B-staff an admin promotes a manager and can step back down")
def t_promote_and_step_down():
    _token, person = make_staff("Jordan", "Blake", "jordan.blake", "manager")

    promoted = call("POST", f"/staff/{person['id']}/role", token=counselor_token(),
                    payload={"role": "admin"})
    assert promoted["staff"]["role"] == "admin", promoted

    # With two admins, either can now be stepped down.
    stepped = call("POST", f"/staff/{person['id']}/role", token=counselor_token(),
                   payload={"role": "manager"})
    assert stepped["staff"]["role"] == "manager", stepped


@test("B-staff the last admin cannot be removed or demoted")
def t_last_admin_protected():
    me = call("GET", "/me", token=counselor_token())["account"]
    staff = call("GET", "/staff", token=counselor_token())
    assert staff["admins"] >= 1, staff

    # Reduce to exactly one admin, whoever else may have been promoted.
    for member in staff["staff"]:
        if member["role"] == "admin" and member["id"] != me["id"]:
            call("POST", f"/staff/{member['id']}/role", token=counselor_token(),
                 payload={"role": "manager"})

    body = expect_status(409, "POST", f"/staff/{me['id']}/role", token=counselor_token(),
                         payload={"role": "manager"})
    assert body["code"] == "last_admin", body
    body = expect_status(409, "DELETE", f"/staff/{me['id']}", token=counselor_token())
    assert body["code"] == "last_admin", body

    # The program still has its admin.
    assert call("GET", "/me", token=counselor_token())["account"]["role"] == "admin"


@test("B-staff removing a manager keeps the hours they approved")
def t_removed_staff_keeps_approvals():
    token, leaver = make_staff("Leaving", "Soon", "leaving.soon", "manager")
    student_token, student = make_student(11, "Kept", "kepthours1")
    entry = make_entry(student_token, hours=7.5)
    call("POST", f"/entries/{entry['id']}/submit", token=student_token)
    call("POST", f"/entries/{entry['id']}/decision", token=token,
         payload={"action": "approve", "note": "Verified before leaving"})

    call("DELETE", f"/staff/{leaver['id']}", token=counselor_token())

    # Their session is gone.
    expect_status(401, "GET", "/me", token=token)

    # The hours they approved still count, and the record still says who.
    progress = call("GET", "/progress", token=student_token)["progress"]
    assert progress["verifiedHours"] == 7.5, progress
    history = call("GET", f"/entries/{entry['id']}/history", token=counselor_token())["history"]
    approved = [h for h in history if h["action"] == "entry.approved"]
    assert approved, history
    assert approved[0]["actorId"] == leaver["id"], approved


@test("B-staff a student account cannot be given staff access")
def t_student_cannot_be_promoted():
    _token, student = make_student(10, "Notstaff", "notstaff1")
    body = expect_status(400, "POST", f"/staff/{student['id']}/role",
                         token=counselor_token(), payload={"role": "manager"})
    assert body["code"] == "not_staff", body


@test("B-reset an admin issues a reset code and the person sets a new password")
def t_password_reset():
    token, person = make_staff("Forgot", "Password", "forgot.password", "manager")

    reset = call("POST", "/password-resets", token=counselor_token(),
                 payload={"accountId": person["id"]})
    assert reset["for"] == "Forgot Password", reset

    call("POST", "/auth/reset", payload={"code": reset["code"], "password": "brandnewpass1"})

    # The old password no longer works and the old session was cut.
    expect_status(401, "POST", "/auth/login", payload={
        "username": "forgot.password", "password": "password123",
    })
    expect_status(401, "GET", "/me", token=token)

    # The new one does, and the role is untouched.
    fresh = call("POST", "/auth/login", payload={
        "username": "forgot.password", "password": "brandnewpass1",
    })
    assert fresh["account"]["role"] == "manager", fresh


@test("B-reset a reset code works once and refuses bad input")
def t_password_reset_guards():
    _token, person = make_staff("Single", "Use", "single.use", "manager")
    reset = call("POST", "/password-resets", token=counselor_token(),
                 payload={"accountId": person["id"]})

    call("POST", "/auth/reset", payload={"code": reset["code"], "password": "firstnewpass1"})
    body = expect_status(400, "POST", "/auth/reset",
                         payload={"code": reset["code"], "password": "secondnewpass1"})
    assert body["code"] == "code_used", body

    expect_status(400, "POST", "/auth/reset",
                  payload={"code": "ZZZZZZZZ", "password": "whatever12"})
    expect_status(400, "POST", "/auth/reset", payload={"code": "", "password": "whatever12"})

    # A password that is too short is refused before anything is consumed.
    another = call("POST", "/password-resets", token=counselor_token(),
                   payload={"accountId": person["id"]})
    expect_status(400, "POST", "/auth/reset",
                  payload={"code": another["code"], "password": "short"})
    call("POST", "/auth/reset", payload={"code": another["code"], "password": "stillvalid1"})


@test("B-reset an expired reset code is refused")
def t_password_reset_expiry():
    _token, person = make_staff("Expired", "Reset", "expired.reset", "manager")
    reset = call("POST", "/password-resets", token=counselor_token(),
                 payload={"accountId": person["id"]})
    _state["service"].conn.execute(
        "UPDATE password_resets SET expires_at = ? WHERE code = ?",
        (time.time() - 60, reset["code"]),
    )
    body = expect_status(400, "POST", "/auth/reset",
                         payload={"code": reset["code"], "password": "toolatenow1"})
    assert body["code"] == "code_expired", body


@test("B-staff an entry records who approved it, by name")
def t_entry_names_its_approver():
    reviewer_token, reviewer = make_staff("Dana", "Whitfield", "dana.whitfield", "manager")
    student_token, _student = make_student(12, "Approved", "approvedby1")
    entry = make_entry(student_token, hours=3.0)
    call("POST", f"/entries/{entry['id']}/submit", token=student_token)

    before = call("GET", "/entries", token=student_token)["entries"][0]
    assert before["decidedBy"] is None, before

    call("POST", f"/entries/{entry['id']}/decision", token=reviewer_token,
         payload={"action": "approve", "note": "Checked with the organiser"})

    # The student sees who verified their hours, and so does the counselor.
    mine = call("GET", "/entries", token=student_token)["entries"][0]
    assert mine["decidedBy"]["name"] == "Dana Whitfield", mine
    assert mine["decidedBy"]["role"] == "manager", mine
    assert mine["decidedBy"]["action"] == "approve", mine
    assert mine["decidedBy"]["note"] == "Checked with the organiser", mine

    # And the name survives that person losing staff access.
    call("DELETE", f"/staff/{reviewer['id']}", token=counselor_token())
    after = call("GET", "/entries", token=student_token)["entries"][0]
    assert after["decidedBy"]["name"] == "Dana Whitfield", after


@test("B4 a new account defaults to the student role")
def t_default_role():
    _token, account = make_student(9, "Default", "defaultrole")
    assert account["role"] == "student", account


@test("B4 self-service escalation to counselor is 403 and the row is unchanged")
def t_no_escalation():
    token, account = make_student(10, "Climber", "climber")
    body = expect_status(403, "POST", "/me/role", token=token, payload={"role": "counselor"})
    assert body["code"] == "role_immutable", body
    row = _state["service"].conn.execute(
        "SELECT role FROM accounts WHERE id = ?", (account["id"],)
    ).fetchone()
    assert row["role"] == "student", row["role"]
    assert call("GET", "/me", token=token)["account"]["role"] == "student"


@test("B6 a student cannot read another student's entries")
def t_cross_student():
    token_a, _ = make_student(9, "Alpha", "alpha1")
    token_b, account_b = make_student(9, "Bravo", "bravo1")
    entry_b = make_entry(token_b, hours=3)

    mine = call("GET", "/entries", token=token_a)["entries"]
    assert all(e["studentId"] != account_b["id"] for e in mine), mine
    assert entry_b["id"] not in [e["id"] for e in mine]

    # Naming another student's id must not widen what comes back.
    scoped = call("GET", f"/entries?studentId={account_b['id']}", token=token_a)["entries"]
    assert all(e["studentId"] != account_b["id"] for e in scoped), scoped

    expect_status(403, "PATCH", f"/entries/{entry_b['id']}", token=token_a,
                  payload={"hours": 99})
    expect_status(403, "DELETE", f"/entries/{entry_b['id']}", token=token_a)


@test("B6 a student cannot reach the roster or the bulk export")
def t_student_no_roster():
    token, _ = make_student(11, "Nosy", "nosy1")
    expect_status(403, "GET", "/roster", token=token)
    expect_status(403, "GET", "/roster.csv", token=token)
    expect_status(403, "GET", "/invite-codes", token=token)
    expect_status(403, "POST", "/invite-codes", token=token, payload={
        "students": [{"firstName": "Nosy", "lastName": "Student", "grade": 9}]
    })


@test("B6 an unauthenticated caller reaches nothing")
def t_unauthenticated():
    for method, path in (
        ("GET", "/me"), ("GET", "/entries"), ("GET", "/roster"),
        ("GET", "/progress"), ("GET", "/invite-codes"), ("GET", "/checklist"),
    ):
        expect_status(401, method, path)
    expect_status(401, "POST", "/entries", payload={"hours": 1})


@test("B6 the counselor reads every student")
def t_counselor_reads_all():
    rows = call("GET", "/roster", token=counselor_token())["students"]
    assert len(rows) >= 4, len(rows)


@test("B7 a student cannot edit or delete an approved entry")
def t_approved_locked():
    token, _ = make_student(9, "Locked", "locked1")
    entry = make_entry(token, hours=4)
    call("POST", f"/entries/{entry['id']}/submit", token=token)
    approve(entry["id"])

    body = expect_status(403, "PATCH", f"/entries/{entry['id']}", token=token,
                         payload={"hours": 100})
    assert body["code"] == "entry_locked", body
    expect_status(403, "DELETE", f"/entries/{entry['id']}", token=token)

    row = _state["service"].conn.execute(
        "SELECT hours, status FROM hour_entries WHERE id = ?", (entry["id"],)
    ).fetchone()
    assert row["hours"] == 4, row["hours"]
    assert row["status"] == "approved", row["status"]


@test("B7 a student cannot approve anything, including their own entry")
def t_no_self_approve():
    token, _ = make_student(10, "Selfie", "selfie1")
    entry = make_entry(token, hours=6)
    call("POST", f"/entries/{entry['id']}/submit", token=token)
    body = expect_status(403, "POST", f"/entries/{entry['id']}/decision", token=token,
                         payload={"action": "approve"})
    assert body["code"] == "forbidden", body
    row = _state["service"].conn.execute(
        "SELECT status FROM hour_entries WHERE id = ?", (entry["id"],)
    ).fetchone()
    assert row["status"] == "submitted", row["status"]


@test("B7 every illegal status transition is refused")
def t_illegal_transitions():
    token, _ = make_student(11, "Transit", "transit1")

    # submitted -> submitted
    entry = make_entry(token, hours=2)
    call("POST", f"/entries/{entry['id']}/submit", token=token)
    expect_status(403, "POST", f"/entries/{entry['id']}/submit", token=token)

    # a student may not edit a submitted entry
    body = expect_status(403, "PATCH", f"/entries/{entry['id']}", token=token,
                         payload={"hours": 9})
    assert body["code"] == "entry_in_review", body

    # approved -> approved, and approved -> rejected
    approve(entry["id"])
    for action in ("approve", "reject", "request_revision"):
        expect_status(409, "POST", f"/entries/{entry['id']}/decision",
                      token=counselor_token(), payload={"action": action})
    expect_status(403, "POST", f"/entries/{entry['id']}/submit", token=token)

    # a draft cannot be decided
    draft = make_entry(token, hours=1)
    expect_status(409, "POST", f"/entries/{draft['id']}/decision",
                  token=counselor_token(), payload={"action": "approve"})


@test("B7 rejected and revision_requested return to the student as editable")
def t_editable_after_rejection():
    token, _ = make_student(12, "Redo", "redo1")
    for action, expected in (("reject", "rejected"),
                             ("request_revision", "revision_requested")):
        entry = make_entry(token, hours=3)
        call("POST", f"/entries/{entry['id']}/submit", token=token)
        decided = call("POST", f"/entries/{entry['id']}/decision", token=counselor_token(),
                       payload={"action": action, "note": "Needs a supervisor phone number"})
        assert decided["entry"]["status"] == expected, decided
        updated = call("PATCH", f"/entries/{entry['id']}", token=token,
                       payload={"verifierContact": "555-0100"})["entry"]
        assert updated["verifierContact"] == "555-0100", updated
        resubmitted = call("POST", f"/entries/{entry['id']}/submit", token=token)["entry"]
        assert resubmitted["status"] == "submitted", resubmitted


@test("B8 a counselor revision appends history and the original stays retrievable")
def t_audit_permanence():
    token, _ = make_student(9, "History", "history1")
    entry = make_entry(token, hours=8, organization="Animal Shelter")
    call("POST", f"/entries/{entry['id']}/submit", token=token)
    approve(entry["id"])

    call("PATCH", f"/entries/{entry['id']}", token=counselor_token(),
         payload={"hours": 6, "note": "Supervisor confirmed 6, not 8"})

    history = call("GET", f"/entries/{entry['id']}/history", token=counselor_token())["history"]
    actions = [h["action"] for h in history]
    assert "entry.approved" in actions, actions
    assert "entry.revised_by_staff" in actions, actions

    revision = next(h for h in history if h["action"] == "entry.revised_by_staff")
    assert revision["before"]["hours"] == 8, revision["before"]
    assert revision["after"]["hours"] == 6, revision["after"]

    current = _state["service"].conn.execute(
        "SELECT hours FROM hour_entries WHERE id = ?", (entry["id"],)
    ).fetchone()
    assert current["hours"] == 6, current["hours"]


@test("B8 the audit log rejects UPDATE and DELETE")
def t_audit_append_only():
    conn = _state["service"].conn
    for statement, params in (
        ("UPDATE audit_log SET action = 'tampered' WHERE id = (SELECT MIN(id) FROM audit_log)", ()),
        ("DELETE FROM audit_log WHERE id = (SELECT MIN(id) FROM audit_log)", ()),
    ):
        try:
            conn.execute(statement, params)
        except Exception as exc:  # noqa: BLE001
            assert "append-only" in str(exc), exc
        else:
            raise AssertionError(f"audit_log allowed: {statement}")


@test("B9 totals count approved hours only, never pending ones")
def t_totals_approved_only():
    token, _ = make_student(9, "Totals", "totals1")
    approved = make_entry(token, hours=10, category="community")
    call("POST", f"/entries/{approved['id']}/submit", token=token)
    approve(approved["id"])

    pending = make_entry(token, hours=7, category="school-based")
    call("POST", f"/entries/{pending['id']}/submit", token=token)

    draft = make_entry(token, hours=4, category="faith-based")
    assert draft["status"] == "draft"

    rejected = make_entry(token, hours=99, category="community")
    call("POST", f"/entries/{rejected['id']}/submit", token=token)
    call("POST", f"/entries/{rejected['id']}/decision", token=counselor_token(),
         payload={"action": "reject"})

    progress = call("GET", "/progress", token=token)["progress"]
    assert progress["verifiedHours"] == 10, progress
    assert progress["pendingHours"] == 7, progress
    assert progress["verifiedHours"] + progress["pendingHours"] != 121, progress
    assert progress["thresholdHours"] == 25, progress
    assert progress["percentComplete"] == 40.0, progress
    assert progress["byCategory"] == {"community": 10.0}, progress


@test("B9 zero hours, exactly at threshold, and over threshold")
def t_totals_boundaries():
    # 0 hours
    token_zero, _ = make_student(9, "Zero", "zero1")
    progress = call("GET", "/progress", token=token_zero)["progress"]
    assert progress["verifiedHours"] == 0, progress
    assert progress["percentComplete"] == 0.0, progress

    # exactly 25 for a freshman
    token_exact, _ = make_student(9, "Exact", "exact1")
    entry = make_entry(token_exact, hours=25)
    call("POST", f"/entries/{entry['id']}/submit", token=token_exact)
    approve(entry["id"])
    progress = call("GET", "/progress", token=token_exact)["progress"]
    assert progress["verifiedHours"] == 25, progress
    assert progress["percentComplete"] == 100.0, progress

    # over threshold
    token_over, _ = make_student(9, "Over", "over1")
    for hours in (25, 5):
        entry = make_entry(token_over, hours=hours)
        call("POST", f"/entries/{entry['id']}/submit", token=token_over)
        approve(entry["id"])
    progress = call("GET", "/progress", token=token_over)["progress"]
    assert progress["verifiedHours"] == 30, progress
    assert progress["percentComplete"] == 120.0, progress


@test("B9 identical hours give different percentages in different grades")
def t_totals_grade_difference():
    token_9, _ = make_student(9, "Fresh", "fresh1")
    token_12, _ = make_student(12, "Senior", "senior1")
    for token in (token_9, token_12):
        entry = make_entry(token, hours=50)
        call("POST", f"/entries/{entry['id']}/submit", token=token)
        approve(entry["id"])

    p9 = call("GET", "/progress", token=token_9)["progress"]
    p12 = call("GET", "/progress", token=token_12)["progress"]

    assert p9["verifiedHours"] == p12["verifiedHours"] == 50, (p9, p12)
    assert p9["thresholdHours"] == 25 and p12["thresholdHours"] == 100, (p9, p12)
    assert p9["percentComplete"] == 200.0, p9
    assert p12["percentComplete"] == 50.0, p12
    assert p9["percentComplete"] != p12["percentComplete"]
    assert p9["submissionDeadline"] == "April 15", p9
    assert p12["submissionDeadline"] == "April 1", p12


@test("B9 per-category breakdown adds up")
def t_category_breakdown():
    token, _ = make_student(11, "Cats", "cats1")
    for hours, category in ((6, "community"), (4, "school-based"), (2.5, "community")):
        entry = make_entry(token, hours=hours, category=category)
        call("POST", f"/entries/{entry['id']}/submit", token=token)
        approve(entry["id"])
    progress = call("GET", "/progress", token=token)["progress"]
    assert progress["byCategory"] == {"community": 8.5, "school-based": 4.0}, progress
    assert progress["verifiedHours"] == 12.5, progress
    assert sum(progress["byCategory"].values()) == progress["verifiedHours"]


@test("B10 the roster filters by grade and by last-name letter range")
def t_roster_filters():
    cohort = [(9, "Adams", "ra1"), (9, "Brooks", "rb1"), (10, "Castro", "rc1"),
              (11, "Delgado", "rd1"), (12, "Ellis", "re1")]
    for grade, last_name, username in cohort:
        make_student(grade, last_name, username)

    all_rows = call("GET", "/roster", token=counselor_token())["students"]
    names = [r["lastName"] for r in all_rows]
    assert names == sorted(names, key=str.lower), names

    grade_9 = call("GET", "/roster?grade=9", token=counselor_token())["students"]
    assert grade_9 and all(r["grade"] == 9 for r in grade_9), grade_9

    letters = call("GET", "/roster?letterFrom=A&letterTo=C", token=counselor_token())
    returned = {r["lastName"] for r in letters["students"]}
    assert {"Adams", "Brooks", "Castro"} <= returned, returned
    assert "Delgado" not in returned and "Ellis" not in returned, returned
    assert all(r["lastName"][0].upper() <= "C" for r in letters["students"])


@test("B10 the roster CSV carries a known value")
def t_roster_csv():
    token, _ = make_student(10, "Csvcheck", "csvcheck1")
    entry = make_entry(token, hours=17, organization="Library")
    call("POST", f"/entries/{entry['id']}/submit", token=token)
    approve(entry["id"])

    csv_text = call("GET", "/roster.csv", token=counselor_token(), raw=True)
    lines = [line for line in csv_text.strip().split("\n") if line]
    assert lines[0].startswith("Last name,Student,Grade"), lines[0]
    row = next(line for line in lines if "Csvcheck" in line)
    assert "17" in row, row
    assert "50" in row, row  # a sophomore's threshold
    rows_in_csv = len(lines) - 1
    roster_count = call("GET", "/roster", token=counselor_token())["count"]
    assert rows_in_csv == roster_count, (rows_in_csv, roster_count)


@test("B10 the counselor can log hours on a student's behalf, flagged as such")
def t_counselor_entered():
    token, account = make_student(9, "Paper", "paper1")
    entry = call("POST", "/entries", token=counselor_token(), payload={
        "studentId": account["id"], "serviceDate": "2026-08-15", "hours": 9,
        "category": "community", "organization": "Onion Festival",
        "description": "Paper form handed in at the front office",
        "verifierName": "Event Lead", "verifierContact": "lead@example.org",
    })["entry"]
    assert entry["counselorEntered"] is True, entry
    assert entry["status"] == "submitted", entry

    approve(entry["id"])
    progress = call("GET", "/progress", token=token)["progress"]
    assert progress["verifiedHours"] == 9, progress

    history = call("GET", f"/entries/{entry['id']}/history", token=counselor_token())["history"]
    created = next(h for h in history if h["action"] == "entry.created")
    assert created["actorRole"] in ("admin", "manager"), created
    assert created["after"]["counselorEntered"] is True, created


@test("B11 deleting an account removes every personal identifier")
def t_account_deletion():
    token, account = make_student(12, "Erasure", "erasure1")
    entry = make_entry(token, hours=12, organization="Habitat for Humanity")
    call("POST", f"/entries/{entry['id']}/submit", token=token)
    approve(entry["id"])

    call("DELETE", "/me", token=token)

    conn = _state["service"].conn
    row = conn.execute(
        "SELECT display_name, last_name, username, deleted_at FROM accounts WHERE id = ?",
        (account["id"],),
    ).fetchone()
    assert row["deleted_at"] is not None, row
    assert "Erasure" not in row["display_name"], row["display_name"]
    assert row["last_name"] == "Deleted", row["last_name"]
    assert "erasure1" not in row["username"], row["username"]

    kept = conn.execute(
        "SELECT hours, organization, description, verifier_name, verifier_contact"
        " FROM hour_entries WHERE id = ?", (entry["id"],),
    ).fetchone()
    assert kept["hours"] == 12, "the hour total is retained"
    assert kept["organization"] == "Redacted", kept["organization"]
    assert kept["description"] == "", kept["description"]
    assert kept["verifier_contact"] == "", kept["verifier_contact"]

    # The session is gone and the name no longer appears anywhere queryable.
    expect_status(401, "GET", "/me", token=token)
    leaked = conn.execute(
        "SELECT COUNT(*) AS n FROM accounts WHERE display_name LIKE '%Erasure%'"
        " OR last_name LIKE '%Erasure%' OR username LIKE '%erasure1%'"
    ).fetchone()["n"]
    assert leaked == 0, f"{leaked} rows still carry the identifier"

    roster = call("GET", "/roster", token=counselor_token())["students"]
    assert all("Erasure" not in r["lastName"] for r in roster), roster


@test("B11 a deleted account cannot sign back in")
def t_deleted_cannot_login():
    expect_status(401, "POST", "/auth/login",
                  payload={"username": "erasure1", "password": "password123"})


@test("B-checklist checklist state is per student, per grade, and persists")
def t_checklist():
    token_9, _ = make_student(9, "Checks", "checks9")
    token_12, _ = make_student(12, "Checks", "checks12")

    items_9 = call("GET", "/checklist", token=token_9)["items"]
    items_12 = call("GET", "/checklist", token=token_12)["items"]
    ids_9 = {i["id"] for i in items_9}
    ids_12 = {i["id"] for i in items_12}

    # The three-organization rule is a senior requirement only.
    assert "three-organizations" in ids_12, ids_12
    assert "three-organizations" not in ids_9, ids_9

    assert all(not i["checked"] for i in items_9)
    call("PUT", "/checklist/membership-fee", token=token_9, payload={"checked": True})
    again = call("GET", "/checklist", token=token_9)["items"]
    assert next(i for i in again if i["id"] == "membership-fee")["checked"] is True

    # One student's checklist is not another's.
    other = call("GET", "/checklist", token=token_12)["items"]
    assert next(i for i in other if i["id"] == "membership-fee")["checked"] is False


@test("B-export the student export contains approved rows only")
def t_student_export():
    token, _ = make_student(11, "Export", "export1")
    approved_entries = [
        make_entry(token, hours=5, organization="Food Bank", date="2026-07-01"),
        make_entry(token, hours=3, organization="Animal Shelter", date="2026-07-15"),
    ]
    for entry in approved_entries:
        call("POST", f"/entries/{entry['id']}/submit", token=token)
        approve(entry["id"])

    pending = make_entry(token, hours=40, organization="Should Not Appear")
    call("POST", f"/entries/{pending['id']}/submit", token=token)

    csv_text = call("GET", "/export.csv", token=token, raw=True)
    lines = [line for line in csv_text.strip().split("\n") if line]
    assert len(lines) == 3, f"header + 2 approved rows, got {len(lines)}: {lines}"
    assert "Animal Shelter" in csv_text, csv_text
    assert "Should Not Appear" not in csv_text, csv_text


@test("B-validation bad input is refused with a useful message")
def t_validation():
    token, _ = make_student(9, "Invalid", "invalid1")
    base = {
        "serviceDate": "2026-09-01", "hours": 3, "category": "community",
        "organization": "Food Bank", "description": "Sorted donations",
        "verifierName": "Supervisor", "verifierContact": "s@example.org",
    }
    for override, expected in (
        ({"hours": -1}, "bad_hours"),
        ({"hours": 0}, "bad_hours"),
        ({"category": "made-up"}, "bad_category"),
        ({"serviceDate": "September 1"}, "bad_date"),
        ({"organization": "   "}, "blank_field"),
    ):
        payload = dict(base)
        payload.update(override)
        body = expect_status(400, "POST", "/entries", token=token, payload=payload)
        assert body["code"] == expected, (override, body)


@test("B-secrets no credentials are committed to the repository")
def t_no_secrets():
    import re
    import subprocess as sp

    tracked = sp.run(
        ["git", "-C", ROOT, "ls-files"], capture_output=True, text=True
    ).stdout.split()
    if not tracked:
        tracked = []
        for base, dirs, files in os.walk(ROOT):
            dirs[:] = [d for d in dirs if d not in
                       {".git", "build", ".build", "DerivedData", "node_modules"}]
            for name in files:
                tracked.append(os.path.relpath(os.path.join(base, name), ROOT))

    patterns = [
        (re.compile(r"eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}"), "JWT / Supabase key"),
        (re.compile(r"sk-[A-Za-z0-9]{32,}"), "secret key"),
        (re.compile(r"service_role"), "Supabase service-role key"),
        (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key"),
        (re.compile(r"AKIA[0-9A-Z]{16}"), "AWS access key"),
    ]
    hits = []
    for relative in tracked:
        path = os.path.join(ROOT, relative)
        if not os.path.isfile(path) or os.path.getsize(path) > 2_000_000:
            continue
        if relative.endswith((".pdf", ".png", ".jpg", ".db")):
            continue
        try:
            text = open(path, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for pattern, label in patterns:
            if pattern.search(text):
                hits.append(f"{relative}: {label}")
    assert not hits, f"secrets found: {hits}"


# ---------------------------------------------------------------------- main


def main():
    if not (os.path.exists(CERT) and os.path.exists(KEY)):
        print(f"missing TLS certificate. Run tools/gen-certs.sh first.", file=sys.stderr)
        return 2

    workdir = tempfile.mkdtemp(prefix="greencord-tests-")
    db_path = os.path.join(workdir, "test.db")

    provision = subprocess.run(
        [sys.executable, os.path.join(ROOT, "tools", "provision-counselor.py"),
         "--db", db_path, "--username", "counselor", "--password", "counselorpass1"],
        capture_output=True, text=True,
    )
    if provision.returncode != 0:
        print(provision.stdout + provision.stderr, file=sys.stderr)
        return 2
    print(provision.stdout.strip())

    httpd = server_module.build_server(db_path, PORT, CERT, KEY)
    _state["service"] = server_module.Handler.service
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()

    for _ in range(60):
        try:
            call("GET", "/health")
            break
        except Exception:  # noqa: BLE001
            time.sleep(0.1)
    else:
        print("server did not come up", file=sys.stderr)
        return 2

    login = call("POST", "/auth/login",
                 payload={"username": "counselor", "password": "counselorpass1"})
    _state["counselor_token"] = login["token"]

    print(f"\nrunning {len(results)} backend tests against {BASE}\n")
    passed, failed = 0, []
    for name, fn in results:
        try:
            fn()
        except Exception as exc:  # noqa: BLE001
            failed.append((name, exc))
            print(f"  FAIL  {name}\n          {exc}")
        else:
            passed += 1
            print(f"  ok    {name}")

    httpd.shutdown()
    print()
    print(f"{passed} passed, {len(failed)} failed, {len(results)} total")
    if failed:
        print("\nFAILURES")
        for name, exc in failed:
            print(f"  {name}: {exc}")
        return 1
    print("BACKEND SUITE PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
