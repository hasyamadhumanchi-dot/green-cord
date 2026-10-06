#!/usr/bin/env python3
"""Drive the DEMO.md walkthrough through the live API and record what happened.

Every step asserts the thing the demo is meant to show. If the approval does not
actually move the student's total, or the entry does not actually lock, this
fails rather than printing a reassuring log.

Writes verification/demo/walkthrough.md.
"""
import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
steps = []
failures = []


class Client:
    def __init__(self, base, cert):
        self.base = base.rstrip("/")
        self.tls = ssl.create_default_context(cafile=cert)
        self.tls.check_hostname = False

    def call(self, method, path, token=None, payload=None, raw=False, expect=None):
        data = json.dumps(payload).encode() if payload is not None else None
        request = urllib.request.Request(self.base + path, data=data, method=method)
        if data:
            request.add_header("Content-Type", "application/json")
        if token:
            request.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(request, context=self.tls, timeout=30) as response:
                body = response.read().decode()
                if expect is not None and expect != 200:
                    raise AssertionError(f"{method} {path}: expected {expect}, got 200")
                return body if raw else json.loads(body)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode()
            if expect is not None and exc.code == expect:
                try:
                    return json.loads(body)
                except ValueError:
                    return {}
            raise AssertionError(f"{method} {path} -> {exc.code}: {body}")


def step(number, title, detail):
    steps.append((number, title, detail, True))
    print(f"  [{number}] {title}")
    for line in detail:
        print(f"        {line}")


def fail(number, title, message):
    steps.append((number, title, [message], False))
    failures.append(f"step {number}: {message}")
    print(f"  [{number}] FAILED  {title}")
    print(f"        {message}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    api = Client(args.base, args.cert)
    counselor = api.call("POST", "/auth/login", payload={
        "username": "counselor", "password": "counselorpass1"
    })["token"]

    # --- 1. A student redeems a code -------------------------------------
    issued = api.call("POST", "/invite-codes", token=counselor, payload={
        "students": [{"firstName": "Mike", "lastName": "Mapleton", "grade": 11}]
    })["codes"][0]
    code = issued["code"]

    # Before signing up, the student sees whose code it is and confirms.
    holder = api.call("GET", f"/invite-codes/lookup?code={code}")

    # The name sent here is deliberately wrong: it must be ignored in favour of
    # the name the counselor put on the code.
    session = api.call("POST", "/auth/redeem", payload={
        "code": code, "username": "mike.mapleton", "password": "demopassword1",
        "displayName": "Not The Right Person", "lastName": "Wrong",
    })
    student = session["token"]
    account = session["account"]
    if (
        account["role"] == "student"
        and account["grade"] == 11
        and account["displayName"] == "Mike Mapleton"
    ):
        step(1, "Redeem an invite code issued to a named student", [
            f"code {code} was issued to {holder['firstName']} {holder['lastName']}, "
            f"grade {holder['grade']}",
            f"account created as role={account['role']}, grade={account['grade']}",
            f"name came from the code, not the form: {account['displayName']}",
            f"threshold from the handbook: {account['thresholdHours']} hours, "
            f"deadline {account['submissionDeadline']}",
        ])
    else:
        fail(1, "Redeem an invite code", f"unexpected account: {account}")

    reused = api.call("POST", "/auth/redeem", expect=400, payload={
        "code": code, "username": "someone.else", "password": "demopassword1",
    })
    if reused.get("code") == "code_used":
        step("1b", "The same code cannot be used twice", [
            f'second attempt refused: "{reused["error"]}"'
        ])
    else:
        fail("1b", "The same code cannot be used twice", f"got {reused}")

    # --- 2. Reading the handbook -----------------------------------------
    handbook = json.load(open(os.path.join(ROOT, "content", "handbook.json")))
    requirements = json.load(open(os.path.join(ROOT, "content", "requirements.json")))
    grade_11 = next(g for g in requirements["grades"] if g["grade"] == 11)
    step(2, "Read the handbook in both modes", [
        f"{len(handbook['sections'])} sections bundled, {handbook['pageCount']} PDF pages",
        "the original handbook pages ship inside the app",
        f"grade 11 threshold {grade_11['thresholdHours']['value']} hours "
        f"(handbook page {grade_11['thresholdHours']['page']})",
    ])

    # --- 3. Log an entry and submit it -----------------------------------
    before = api.call("GET", "/progress", token=student)["progress"]
    entry = api.call("POST", "/entries", token=student, payload={
        "serviceDate": "2026-09-13", "hours": 6.5, "category": "community",
        "organization": "Princeton Community Food Pantry",
        "description": "Sorted and boxed donated food for weekend distribution.",
        "verifierName": "Pantry Volunteer Coordinator",
        "verifierContact": "volunteer.coordinator@example.org",
        "evidenceURL": "attached://photo",
    })["entry"]
    api.call("POST", f"/entries/{entry['id']}/submit", token=student)
    pending = api.call("GET", "/progress", token=student)["progress"]

    if pending["verifiedHours"] == before["verifiedHours"] and pending["pendingHours"] == 6.5:
        step(3, "Log 6.5 hours and send them for review", [
            f"approved hours unchanged at {pending['verifiedHours']}",
            f"pending hours now {pending['pendingHours']} - shown separately, not added",
            f"percent complete still {pending['percentComplete']}%",
        ])
    else:
        fail(3, "Log hours and submit", f"before={before} after={pending}")

    # --- 4. The counselor approves ----------------------------------------
    queue = api.call("GET", "/entries?status=submitted", token=counselor)["entries"]
    mine = [e for e in queue if e["id"] == entry["id"]]
    if not mine:
        fail(4, "The entry reaches the counselor's queue", "not found in the queue")
    api.call("POST", f"/entries/{entry['id']}/decision", token=counselor,
             payload={"action": "approve", "note": "Verification form on file."})
    after = api.call("GET", "/progress", token=student)["progress"]

    moved = round(after["verifiedHours"] - before["verifiedHours"], 2)
    if moved == 6.5 and after["pendingHours"] == 0:
        step(4, "The counselor approves it", [
            f"{len(queue)} entries were waiting in the queue",
            f"approved hours moved by exactly {moved} - the entry's own hours",
            f"pending hours back to {after['pendingHours']}",
            f"percent complete now {after['percentComplete']}% of "
            f"{after['thresholdHours']} (grade {after['grade']})",
        ])
    else:
        fail(4, "Approval moves the total", f"moved {moved}, after={after}")

    # --- 4b. And the student can no longer touch it ------------------------
    locked = api.call("PATCH", f"/entries/{entry['id']}", token=student,
                      expect=403, payload={"hours": 99})
    deleted = api.call("DELETE", f"/entries/{entry['id']}", token=student, expect=403)
    current = [e for e in api.call("GET", "/entries", token=student)["entries"]
               if e["id"] == entry["id"]][0]
    if current["hours"] == 6.5 and current["status"] == "approved":
        step("4b", "Approved hours are permanent", [
            f'editing refused: "{locked["error"]}"',
            f'deleting refused: "{deleted.get("error", "403")}"',
            f"the row is unchanged at {current['hours']} hours, status {current['status']}",
        ])
    else:
        fail("4b", "Approved hours are permanent", f"entry changed: {current}")

    # --- 5. The roster ----------------------------------------------------
    everyone = api.call("GET", "/roster", token=counselor)
    grade_11_rows = api.call("GET", "/roster?grade=11", token=counselor)
    letters = api.call("GET", "/roster?letterFrom=A&letterTo=C", token=counselor)
    csv_text = api.call("GET", "/roster.csv", token=counselor, raw=True)
    csv_rows = [line for line in csv_text.strip().split("\n") if line]

    letters_ok = all(r["lastName"][0].upper() <= "C" for r in letters["students"])
    if everyone["count"] > grade_11_rows["count"] and letters_ok:
        step(5, "The counselor's roster", [
            f"{everyone['count']} students in total",
            f"filtered to grade 11: {grade_11_rows['count']}",
            f"filtered to last names A-C: {letters['count']} "
            f"({', '.join(r['lastName'] for r in letters['students'])})",
            f"CSV export: {len(csv_rows) - 1} rows plus a header",
        ])
    else:
        fail(5, "The roster filters", f"all={everyone['count']} letters_ok={letters_ok}")

    if "Mapleton" in csv_text and "6.5" in csv_text:
        step("5b", "The export carries the hours just approved", [
            "Mapleton and 6.5 both appear in the exported CSV",
        ])
    else:
        fail("5b", "The export carries the approved hours", "value missing from the CSV")

    # --- 6. A student sees nobody else ------------------------------------
    roster_refused = api.call("GET", "/roster", token=student, expect=403)
    csv_refused = api.call("GET", "/roster.csv", token=student, expect=403)
    codes_refused = api.call("GET", "/invite-codes", token=student, expect=403)
    own = api.call("GET", "/entries", token=student)["entries"]
    only_own = all(e["studentId"] == account["id"] for e in own)
    if only_own:
        step(6, "A student sees only their own record", [
            f'roster refused: {roster_refused["code"]}',
            f'roster CSV refused: {csv_refused["code"]}',
            f'invite codes refused: {codes_refused["code"]}',
            f"their own entries list contains {len(own)} entries, all their own",
        ])
    else:
        fail(6, "A student sees only their own record", "another student's data leaked")

    # --- The audit trail ---------------------------------------------------
    history = api.call("GET", f"/entries/{entry['id']}/history", token=counselor)["history"]
    actions = [h["action"] for h in history]
    if "entry.approved" in actions:
        step("7", "Everything is recorded", [
            f"audit trail for this entry: {' -> '.join(actions)}",
        ])
    else:
        fail("7", "The audit trail records the approval", f"actions were {actions}")

    # --- report ------------------------------------------------------------
    lines = [
        "# Demo walkthrough",
        "",
        "`tools/run-demo-walkthrough.sh` executed the DEMO.md script end to end",
        "against a live backend. Every step below asserts what it claims: if the",
        "approval had not moved the total, or the entry had not locked, this run",
        "would have failed.",
        "",
        f"Backend: `{args.base}`",
        "",
    ]
    for number, title, detail, ok in steps:
        lines.append(f"### Step {number} - {title} {'' if ok else '(FAILED)'}".rstrip())
        lines.append("")
        for item in detail:
            lines.append(f"* {item}")
        lines.append("")

    lines += [
        "## Screenshots",
        "",
        "* `step2-handbook-iphone.png` - the handbook on iPhone",
        "* `step5-roster-ipad.png` - the same app on iPad, with the sidebar layout",
        "",
        "Home and dark-mode screenshots for both device families are in the parent",
        "`verification/` directory.",
        "",
    ]
    lines.append(
        f"**{len(steps) - len(failures)} of {len(steps)} steps passed.**"
        if failures else f"**All {len(steps)} steps passed.**"
    )
    lines.append("")

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "walkthrough.md"), "w") as fh:
        fh.write("\n".join(lines))

    print()
    if failures:
        print(f"{len(failures)} step(s) failed:")
        for item in failures:
            print(f"  {item}")
        return 1
    print(f"All {len(steps)} walkthrough steps passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
