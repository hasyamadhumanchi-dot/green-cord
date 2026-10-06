#!/usr/bin/env python3
"""Green Cord prototype backend: HTTPS, session tokens, server-enforced rules.

Run it:
    python3 backend/server.py --db build/greencord.db --port 8443

Every authorization decision lives here. The iOS client is not trusted: it holds
a session token and nothing more. The rules this file enforces are the same ones
expressed as Postgres row-level-security policies in migrations/0001_init.sql,
which is what deploys to Supabase once the program is approved.

Rules, in one place:
  * An account is created only by redeeming a valid, unexpired, unrevoked,
    unredeemed invite code. There is no other sign-up path.
  * Every account created through the API is a student. No endpoint sets a role.
    The counselor account is created by tools/provision-counselor.py, which
    writes to the database directly and is never reachable over HTTP.
  * A student reads and writes only their own entries, and can see nothing about
    any other student - no roster, no totals, no ranking.
  * draft -> submitted -> (approved | rejected | revision_requested).
    `approved` is terminal for the student: no edit, no delete, no resubmit.
  * Only the counselor decides. A student decisioning anything is 403.
  * Approving writes an approvals row and an audit_log row. A later counselor
    revision appends another audit_log row; nothing is overwritten.
  * Totals are computed here from approved entries only, against the student's
    grade-level threshold taken from content/requirements.json.
"""
import argparse
import csv
import io
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import db  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REQUIREMENTS_PATH = os.path.join(ROOT, "content", "requirements.json")

STUDENT_EDITABLE = {"draft", "rejected", "revision_requested"}
TERMINAL_FOR_STUDENT = {"approved"}
DECISIONS = {
    "approve": "approved",
    "reject": "rejected",
    "request_revision": "revision_requested",
}

ENTRY_FIELDS = (
    "service_date", "hours", "category", "organization", "description",
    "verifier_name", "verifier_contact", "evidence_url",
)


class HttpError(Exception):
    def __init__(self, status, message, code=None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.code = code or message.lower().replace(" ", "_")


def load_requirements():
    with open(REQUIREMENTS_PATH) as fh:
        return json.load(fh)


class Service:
    """All behaviour, independent of HTTP, so the tests can hit it either way."""

    def __init__(self, db_path):
        self.db_path = db_path
        self.conn = db.init(db_path)
        # Re-entrant: some operations take the lock and then call others.
        self.lock = threading.RLock()
        self.requirements = load_requirements()
        self.thresholds = {
            g["grade"]: g["thresholdHours"]["value"] for g in self.requirements["grades"]
        }
        self.deadlines = {
            g["grade"]: g["submissionDeadline"]["value"] for g in self.requirements["grades"]
        }
        self.valid_categories = {c["id"] for c in self.requirements["categories"]}

    # ---------------------------------------------------------------- helpers

    def account_or_401(self, token):
        account = db.account_for_token(self.conn, token)
        if account is None:
            raise HttpError(401, "Not signed in", "unauthenticated")
        return account

    STAFF_ROLES = ("manager", "admin")

    def staff_or_403(self, token):
        """A manager or an admin. Everything student-facing is open to both."""
        account = self.account_or_401(token)
        if account["role"] not in self.STAFF_ROLES:
            raise HttpError(403, "Staff access only", "forbidden")
        return account

    def admin_or_403(self, token):
        """An admin. Only they may create, change or remove staff accounts."""
        account = self.account_or_401(token)
        if account["role"] != "admin":
            db.audit(self.conn, account["id"], account["role"], "staff.change_refused")
            raise HttpError(
                403, "Only an admin can manage staff accounts", "admin_only"
            )
        return account

    # Kept so older call sites read correctly; staff is the access level.
    counselor_or_403 = staff_or_403

    def admin_count(self, excluding=None):
        rows = self.conn.execute(
            "SELECT id FROM accounts WHERE role = 'admin' AND deleted_at IS NULL"
        ).fetchall()
        return len([r for r in rows if r["id"] != excluding])

    def account_or_404(self, account_id):
        row = self.conn.execute(
            "SELECT * FROM accounts WHERE id = ? AND deleted_at IS NULL", (account_id,)
        ).fetchone()
        if row is None:
            raise HttpError(404, "No such account", "not_found")
        return row

    def entry_or_404(self, entry_id):
        row = self.conn.execute(
            "SELECT * FROM hour_entries WHERE id = ?", (entry_id,)
        ).fetchone()
        if row is None:
            raise HttpError(404, "No such entry", "not_found")
        return row

    def decided_by(self, entry_id):
        """Who last approved, rejected or returned this entry.

        Surfaced on the entry itself because the counselor asked to see it:
        with several people reviewing, "approved" is only half the answer. The
        name stays attached even after that person loses staff access - an
        approval is a record of who verified the hours.
        """
        row = self.conn.execute(
            "SELECT a.action, a.created_at, a.note, c.display_name, c.role"
            "  FROM approvals a JOIN accounts c ON c.id = a.actor_id"
            " WHERE a.entry_id = ? AND a.action != 'revise'"
            " ORDER BY a.created_at DESC LIMIT 1",
            (entry_id,),
        ).fetchone()
        if row is None:
            return None
        return {
            "name": row["display_name"],
            "role": row["role"],
            "action": row["action"],
            "note": row["note"],
            "at": row["created_at"],
        }

    def entry_json(self, row):
        return {
            "id": row["id"],
            "studentId": row["student_id"],
            "serviceDate": row["service_date"],
            "hours": row["hours"],
            "category": row["category"],
            "organization": row["organization"],
            "description": row["description"],
            "verifierName": row["verifier_name"],
            "verifierContact": row["verifier_contact"],
            "evidenceURL": row["evidence_url"],
            "counselorEntered": bool(row["counselor_entered"]),
            "status": row["status"],
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
            "submittedAt": row["submitted_at"],
            "decidedAt": row["decided_at"],
            "decidedBy": self.decided_by(row["id"]),
        }

    def validate_entry_payload(self, payload, partial=False):
        cleaned = {}
        for field in ENTRY_FIELDS:
            key = {
                "service_date": "serviceDate",
                "verifier_name": "verifierName",
                "verifier_contact": "verifierContact",
                "evidence_url": "evidenceURL",
            }.get(field, field)
            if key not in payload:
                if partial:
                    continue
                if field == "evidence_url":
                    cleaned[field] = None
                    continue
                raise HttpError(400, f"Missing field: {key}", "missing_field")
            cleaned[field] = payload[key]

        if "hours" in cleaned:
            try:
                cleaned["hours"] = float(cleaned["hours"])
            except (TypeError, ValueError):
                raise HttpError(400, "hours must be a number", "bad_hours")
            if cleaned["hours"] <= 0:
                raise HttpError(400, "hours must be greater than zero", "bad_hours")
        if "category" in cleaned and cleaned["category"] not in self.valid_categories:
            raise HttpError(
                400,
                f"Unknown category. Expected one of {sorted(self.valid_categories)}",
                "bad_category",
            )
        if "service_date" in cleaned and not re.match(
            r"^\d{4}-\d{2}-\d{2}$", str(cleaned["service_date"])
        ):
            raise HttpError(400, "serviceDate must be YYYY-MM-DD", "bad_date")
        for field in ("organization", "description", "verifier_name", "verifier_contact"):
            if field in cleaned and not str(cleaned[field]).strip():
                raise HttpError(400, f"{field} cannot be blank", "blank_field")
        return cleaned

    # ------------------------------------------------------------------ auth

    def redeem(self, payload):
        code = str(payload.get("code", "")).strip().upper()
        username = str(payload.get("username", "")).strip().lower()
        password = str(payload.get("password", ""))

        if not code:
            raise HttpError(400, "Enter the invite code from your counselor", "code_missing")
        if not (username and len(password) >= 8):
            raise HttpError(
                400,
                "A username and a password of at least 8 characters are required",
                "details_missing",
            )

        with self.lock:
            row = self.conn.execute(
                "SELECT * FROM invite_codes WHERE code = ?", (code,)
            ).fetchone()
            if row is None:
                raise HttpError(400, "That code was not recognised", "code_unknown")
            if row["revoked_at"] is not None:
                raise HttpError(400, "That code has been cancelled", "code_revoked")
            if row["redeemed_by"] is not None:
                raise HttpError(400, "That code has already been used", "code_used")
            if row["expires_at"] < time.time():
                raise HttpError(400, "That code has expired", "code_expired")
            if self.conn.execute(
                "SELECT 1 FROM accounts WHERE username = ?", (username,)
            ).fetchone():
                raise HttpError(400, "That username is taken", "username_taken")

            self.conn.execute("BEGIN IMMEDIATE")
            try:
                # Claim the code atomically. Two racing redemptions cannot both
                # match `redeemed_by IS NULL`, so exactly one account is created.
                cursor = self.conn.execute(
                    "UPDATE invite_codes SET redeemed_at = ?"
                    " WHERE code = ? AND redeemed_by IS NULL AND revoked_at IS NULL",
                    (time.time(), code),
                )
                if cursor.rowcount != 1:
                    raise HttpError(400, "That code has already been used", "code_used")
                # The name and the role both come from the code, never from
                # the form. Nobody can enrol as someone they were not invited
                # as, and nobody can promote themselves by signing up.
                display_name = f"{row['first_name']} {row['last_name']}".strip()
                account_id = db.create_account(
                    self.conn, row["role"], display_name, row["last_name"],
                    row["grade"], username, password,
                )
                self.conn.execute(
                    "UPDATE invite_codes SET redeemed_by = ? WHERE code = ?",
                    (account_id, code),
                )
                db.audit(self.conn, account_id, row["role"], "account.created",
                         account_id=account_id,
                         after={"role": row["role"], "grade": row["grade"], "code": code})
                self.conn.execute("COMMIT")
            except Exception:
                self.conn.execute("ROLLBACK")
                raise

            token = db.issue_session(self.conn, account_id)
        return {"token": token, "account": self.me(token)["account"]}

    def lookup_code(self, query):
        """Who a code belongs to, so the student confirms rather than types a name.

        Unauthenticated by necessity - it runs before an account exists. It
        reveals only the name already printed on the slip the counselor handed
        out, and only for a code that is still usable. Guessing one means
        finding 8 characters out of a 32-character alphabet, so this is not a
        route to enumerating the roster.
        """
        code = str(query.get("code", [""])[0]).strip().upper()
        if not code:
            raise HttpError(400, "Enter the invite code from your counselor", "code_missing")
        row = self.conn.execute(
            "SELECT * FROM invite_codes WHERE code = ?", (code,)
        ).fetchone()
        if row is None:
            raise HttpError(404, "That code was not recognised", "code_unknown")
        if row["revoked_at"] is not None:
            raise HttpError(400, "That code has been cancelled", "code_revoked")
        if row["redeemed_by"] is not None:
            raise HttpError(400, "That code has already been used", "code_used")
        if row["expires_at"] < time.time():
            raise HttpError(400, "That code has expired", "code_expired")
        return {
            "code": row["code"],
            "firstName": row["first_name"],
            "lastName": row["last_name"],
            "role": row["role"],
            "grade": row["grade"],
        }

    def login(self, payload):
        username = str(payload.get("username", "")).strip().lower()
        password = str(payload.get("password", ""))
        row = self.conn.execute(
            "SELECT * FROM accounts WHERE username = ? AND deleted_at IS NULL", (username,)
        ).fetchone()
        if row is None or not db.verify_password(
            password, row["password_hash"], row["password_salt"]
        ):
            raise HttpError(401, "Username or password is incorrect", "bad_credentials")
        token = db.issue_session(self.conn, row["id"])
        return {"token": token, "account": self.me(token)["account"]}

    def logout(self, token):
        self.conn.execute("DELETE FROM sessions WHERE token = ?", (token,))
        return {"ok": True}

    def me(self, token):
        account = self.account_or_401(token)
        return {
            "account": {
                "id": account["id"],
                "role": account["role"],
                "displayName": account["display_name"],
                "lastName": account["last_name"],
                "grade": account["grade"],
                "username": account["username"],
                "thresholdHours": self.thresholds.get(account["grade"]),
                "submissionDeadline": self.deadlines.get(account["grade"]),
            }
        }

    def set_role(self, token, payload):
        """No path to a role change. Present so the attempt is logged and refused."""
        account = self.account_or_401(token)
        db.audit(self.conn, account["id"], account["role"], "role.escalation_refused",
                 account_id=account["id"], after={"requested": payload.get("role")})
        raise HttpError(
            403,
            "Roles are assigned by the program operator on the server, not through the app",
            "role_immutable",
        )

    def delete_me(self, token):
        """Irreversibly anonymise personal identifiers, keep the hour record."""
        account = self.account_or_401(token)
        now = time.time()
        anon_name = f"Deleted account {account['id'][:8]}"
        with self.lock:
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                self.conn.execute(
                    "UPDATE accounts SET display_name = ?, last_name = ?, username = ?,"
                    " password_hash = '', password_salt = '', deleted_at = ? WHERE id = ?",
                    (anon_name, "Deleted", f"deleted-{account['id']}", now, account["id"]),
                )
                # Entry bodies carry the student's own words and a supervisor's
                # contact details. Both are personal data, so both are cleared.
                self.conn.execute(
                    "UPDATE hour_entries SET description = '', organization = 'Redacted',"
                    " verifier_name = '', verifier_contact = '', evidence_url = NULL"
                    " WHERE student_id = ?",
                    (account["id"],),
                )
                # The invite code carries the name the counselor assigned, so
                # it is an identifier too and has to go the same way.
                self.conn.execute(
                    "UPDATE invite_codes SET first_name = 'Deleted', last_name = 'Account'"
                    " WHERE redeemed_by = ?",
                    (account["id"],),
                )
                self.conn.execute("DELETE FROM sessions WHERE account_id = ?", (account["id"],))
                db.audit(self.conn, account["id"], account["role"], "account.deleted",
                         account_id=account["id"])
                self.conn.execute("COMMIT")
            except Exception:
                self.conn.execute("ROLLBACK")
                raise
        return {"ok": True, "retained": "aggregate hour totals", "removed": "personal identifiers"}

    # --------------------------------------------------------------- entries

    def list_entries(self, token, query):
        account = self.account_or_401(token)
        if account["role"] in self.STAFF_ROLES:
            student_id = query.get("studentId", [None])[0]
            status = query.get("status", [None])[0]
            sql = "SELECT * FROM hour_entries WHERE 1=1"
            params = []
            if student_id:
                sql += " AND student_id = ?"
                params.append(student_id)
            if status:
                sql += " AND status = ?"
                params.append(status)
            sql += " ORDER BY submitted_at IS NULL, submitted_at ASC, created_at ASC"
            rows = self.conn.execute(sql, params).fetchall()
        else:
            # A student asking for somebody else's entries gets their own, never
            # another student's. Nothing here can widen the scope.
            rows = self.conn.execute(
                "SELECT * FROM hour_entries WHERE student_id = ? ORDER BY service_date DESC",
                (account["id"],),
            ).fetchall()
        return {"entries": [self.entry_json(r) for r in rows]}

    def create_entry(self, token, payload):
        account = self.account_or_401(token)
        fields = self.validate_entry_payload(payload)

        if account["role"] in self.STAFF_ROLES:
            student_id = payload.get("studentId")
            if not student_id:
                raise HttpError(400, "studentId is required", "missing_student")
            student = self.conn.execute(
                "SELECT * FROM accounts WHERE id = ? AND role = 'student'"
                " AND deleted_at IS NULL",
                (student_id,),
            ).fetchone()
            if student is None:
                raise HttpError(404, "No such student", "not_found")
            counselor_entered = 1
            status = "submitted"
        else:
            student_id = account["id"]
            counselor_entered = 0
            status = "draft"

        entry_id = db.new_id()
        now = time.time()
        self.conn.execute(
            "INSERT INTO hour_entries (id, student_id, service_date, hours, category,"
            " organization, description, verifier_name, verifier_contact, evidence_url,"
            " counselor_entered, status, created_at, updated_at, submitted_at)"
            " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (entry_id, student_id, fields["service_date"], fields["hours"],
             fields["category"], fields["organization"], fields["description"],
             fields["verifier_name"], fields["verifier_contact"], fields["evidence_url"],
             counselor_entered, status, now, now, now if status == "submitted" else None),
        )
        row = self.entry_or_404(entry_id)
        db.audit(self.conn, account["id"], account["role"], "entry.created",
                 entry_id=entry_id, account_id=student_id, after=self.entry_json(row))
        return {"entry": self.entry_json(row)}

    def update_entry(self, token, entry_id, payload):
        account = self.account_or_401(token)
        row = self.entry_or_404(entry_id)

        if account["role"] == "student":
            if row["student_id"] != account["id"]:
                raise HttpError(403, "Not your entry", "forbidden")
            if row["status"] in TERMINAL_FOR_STUDENT:
                raise HttpError(
                    403,
                    "Approved hours are permanent. Ask your counselor for a correction.",
                    "entry_locked",
                )
            if row["status"] not in STUDENT_EDITABLE:
                raise HttpError(
                    403,
                    "This entry is with your counselor for review and cannot be changed.",
                    "entry_in_review",
                )

        before = self.entry_json(row)
        fields = self.validate_entry_payload(payload, partial=True)
        if not fields:
            raise HttpError(400, "Nothing to change", "empty_update")
        assignments = ", ".join(f"{f} = ?" for f in fields)
        self.conn.execute(
            f"UPDATE hour_entries SET {assignments}, updated_at = ? WHERE id = ?",
            list(fields.values()) + [time.time(), entry_id],
        )
        after = self.entry_json(self.entry_or_404(entry_id))
        action = (
            "entry.revised_by_staff"
            if account["role"] in self.STAFF_ROLES
            else "entry.updated"
        )
        db.audit(self.conn, account["id"], account["role"], action,
                 entry_id=entry_id, account_id=row["student_id"], before=before, after=after)
        if account["role"] in self.STAFF_ROLES:
            self.conn.execute(
                "INSERT INTO approvals (id, entry_id, actor_id, action, note, created_at)"
                " VALUES (?,?,?,?,?,?)",
                (db.new_id(), entry_id, account["id"], "revise",
                 str(payload.get("note", "")), time.time()),
            )
        return {"entry": after}

    def delete_entry(self, token, entry_id):
        account = self.account_or_401(token)
        row = self.entry_or_404(entry_id)
        if account["role"] == "student":
            if row["student_id"] != account["id"]:
                raise HttpError(403, "Not your entry", "forbidden")
            if row["status"] in TERMINAL_FOR_STUDENT:
                raise HttpError(
                    403,
                    "Approved hours are permanent and cannot be deleted.",
                    "entry_locked",
                )
            if row["status"] not in STUDENT_EDITABLE:
                raise HttpError(
                    403,
                    "This entry is with your counselor for review and cannot be deleted.",
                    "entry_in_review",
                )
        before = self.entry_json(row)
        self.conn.execute("DELETE FROM approvals WHERE entry_id = ?", (entry_id,))
        self.conn.execute("DELETE FROM hour_entries WHERE id = ?", (entry_id,))
        db.audit(self.conn, account["id"], account["role"], "entry.deleted",
                 entry_id=entry_id, account_id=row["student_id"], before=before)
        return {"ok": True}

    def submit_entry(self, token, entry_id):
        account = self.account_or_401(token)
        row = self.entry_or_404(entry_id)
        if account["role"] == "student" and row["student_id"] != account["id"]:
            raise HttpError(403, "Not your entry", "forbidden")
        if row["status"] not in STUDENT_EDITABLE:
            raise HttpError(
                403,
                f"An entry that is {row['status']} cannot be submitted again.",
                "illegal_transition",
            )
        before = self.entry_json(row)
        now = time.time()
        self.conn.execute(
            "UPDATE hour_entries SET status = 'submitted', submitted_at = ?, updated_at = ?"
            " WHERE id = ?",
            (now, now, entry_id),
        )
        after = self.entry_json(self.entry_or_404(entry_id))
        db.audit(self.conn, account["id"], account["role"], "entry.submitted",
                 entry_id=entry_id, account_id=row["student_id"], before=before, after=after)
        return {"entry": after}

    def decide_entry(self, token, entry_id, payload):
        account = self.account_or_401(token)
        if account["role"] not in self.STAFF_ROLES:
            db.audit(self.conn, account["id"], account["role"], "entry.decision_refused",
                     entry_id=entry_id, after={"attempted": payload.get("action")})
            raise HttpError(403, "Only staff can review hours", "forbidden")

        action = payload.get("action")
        if action not in DECISIONS:
            raise HttpError(400, f"action must be one of {sorted(DECISIONS)}", "bad_action")

        row = self.entry_or_404(entry_id)
        if row["status"] != "submitted":
            raise HttpError(
                409,
                f"Only a submitted entry can be decided; this one is {row['status']}.",
                "illegal_transition",
            )

        before = self.entry_json(row)
        now = time.time()
        self.conn.execute(
            "UPDATE hour_entries SET status = ?, decided_at = ?, updated_at = ? WHERE id = ?",
            (DECISIONS[action], now, now, entry_id),
        )
        self.conn.execute(
            "INSERT INTO approvals (id, entry_id, actor_id, action, note, created_at)"
            " VALUES (?,?,?,?,?,?)",
            (db.new_id(), entry_id, account["id"], action, str(payload.get("note", "")), now),
        )
        after = self.entry_json(self.entry_or_404(entry_id))
        # Log the resulting status, not the verb, so the history reads
        # entry.approved / entry.rejected / entry.revision_requested.
        db.audit(self.conn, account["id"], account["role"], f"entry.{DECISIONS[action]}",
                 entry_id=entry_id, account_id=row["student_id"], before=before, after=after)
        return {"entry": after}

    def entry_history(self, token, entry_id):
        account = self.account_or_401(token)
        row = self.entry_or_404(entry_id)
        if account["role"] == "student" and row["student_id"] != account["id"]:
            raise HttpError(403, "Not your entry", "forbidden")
        events = self.conn.execute(
            "SELECT l.at, l.actor_id, l.actor_role, l.action, l.before_json, l.after_json,"
            "       a.display_name"
            "  FROM audit_log l LEFT JOIN accounts a ON a.id = l.actor_id"
            " WHERE l.entry_id = ? ORDER BY l.id ASC",
            (entry_id,),
        ).fetchall()
        return {
            "history": [
                {
                    "at": e["at"],
                    "actorId": e["actor_id"],
                    "actorName": e["display_name"],
                    "actorRole": e["actor_role"],
                    "action": e["action"],
                    "before": json.loads(e["before_json"]) if e["before_json"] else None,
                    "after": json.loads(e["after_json"]) if e["after_json"] else None,
                }
                for e in events
            ]
        }

    # -------------------------------------------------------------- progress

    def compute_progress(self, student_id, grade):
        rows = self.conn.execute(
            "SELECT hours, category, organization, status FROM hour_entries"
            " WHERE student_id = ?",
            (student_id,),
        ).fetchall()
        approved = [r for r in rows if r["status"] == "approved"]
        pending = [r for r in rows if r["status"] == "submitted"]

        verified = round(sum(r["hours"] for r in approved), 2)
        pending_hours = round(sum(r["hours"] for r in pending), 2)
        threshold = self.thresholds.get(grade)

        by_category = {}
        for r in approved:
            by_category[r["category"]] = round(
                by_category.get(r["category"], 0.0) + r["hours"], 2
            )
        organisations = sorted({r["organization"] for r in approved})

        percent = round(verified / threshold * 100, 1) if threshold else None
        return {
            "studentId": student_id,
            "grade": grade,
            "thresholdHours": threshold,
            "verifiedHours": verified,
            "pendingHours": pending_hours,
            "percentComplete": percent,
            "byCategory": by_category,
            "distinctOrganizations": len(organisations),
            "organizations": organisations,
            "submissionDeadline": self.deadlines.get(grade),
        }

    def progress(self, token):
        account = self.account_or_401(token)
        if account["role"] != "student":
            raise HttpError(400, "Progress applies to student accounts", "not_a_student")
        return {"progress": self.compute_progress(account["id"], account["grade"])}

    # ---------------------------------------------------------------- roster

    def roster_rows(self, grade=None, letter_from=None, letter_to=None):
        students = self.conn.execute(
            "SELECT * FROM accounts WHERE role = 'student' AND deleted_at IS NULL"
            " ORDER BY last_name COLLATE NOCASE, display_name COLLATE NOCASE"
        ).fetchall()
        rows = []
        for student in students:
            if grade is not None and student["grade"] != grade:
                continue
            initial = (student["last_name"] or " ")[0].upper()
            if letter_from and initial < letter_from.upper():
                continue
            if letter_to and initial > letter_to.upper():
                continue
            progress = self.compute_progress(student["id"], student["grade"])
            last_activity = self.conn.execute(
                "SELECT MAX(updated_at) AS t FROM hour_entries WHERE student_id = ?",
                (student["id"],),
            ).fetchone()["t"]
            rows.append(
                {
                    "studentId": student["id"],
                    "displayName": student["display_name"],
                    "lastName": student["last_name"],
                    "grade": student["grade"],
                    "verifiedHours": progress["verifiedHours"],
                    "pendingHours": progress["pendingHours"],
                    "thresholdHours": progress["thresholdHours"],
                    "percentComplete": progress["percentComplete"],
                    "lastActivityAt": last_activity,
                    "joined": True,
                }
            )

        # Students the counselor has issued a code to who have not signed up
        # yet. Without these the roster would only ever show the students who
        # got round to redeeming, which is the opposite of what it is for.
        pending = self.conn.execute(
            "SELECT * FROM invite_codes"
            " WHERE redeemed_by IS NULL AND revoked_at IS NULL"
            " ORDER BY last_name COLLATE NOCASE, first_name COLLATE NOCASE"
        ).fetchall()
        for code in pending:
            if grade is not None and code["grade"] != grade:
                continue
            initial = (code["last_name"] or " ")[0].upper()
            if letter_from and initial < letter_from.upper():
                continue
            if letter_to and initial > letter_to.upper():
                continue
            threshold = self.thresholds.get(code["grade"])
            rows.append(
                {
                    "studentId": f"code:{code['code']}",
                    "displayName": f"{code['first_name']} {code['last_name']}".strip(),
                    "lastName": code["last_name"],
                    "grade": code["grade"],
                    "verifiedHours": 0.0,
                    "pendingHours": 0.0,
                    "thresholdHours": threshold,
                    "percentComplete": 0.0,
                    "lastActivityAt": None,
                    "joined": False,
                }
            )

        rows.sort(key=lambda row: ((row["lastName"] or "").lower(),
                                   (row["displayName"] or "").lower()))
        return rows

    def roster(self, token, query):
        self.staff_or_403(token)
        grade = query.get("grade", [None])[0]
        rows = self.roster_rows(
            grade=int(grade) if grade else None,
            letter_from=query.get("letterFrom", [None])[0],
            letter_to=query.get("letterTo", [None])[0],
        )
        return {"students": rows, "count": len(rows)}

    def roster_csv(self, token, query):
        self.staff_or_403(token)
        rows = self.roster(token, query)["students"]
        buffer = io.StringIO()
        writer = csv.writer(buffer)
        writer.writerow(
            ["Last name", "Student", "Grade", "Verified hours", "Pending hours",
             "Required hours", "Percent complete", "Signed up"]
        )
        for row in rows:
            writer.writerow(
                [row["lastName"], row["displayName"], row["grade"], row["verifiedHours"],
                 row["pendingHours"], row["thresholdHours"], row["percentComplete"],
                 "Yes" if row.get("joined", True) else "No"]
            )
        return buffer.getvalue()

    def student_export_csv(self, token):
        account = self.account_or_401(token)
        rows = self.conn.execute(
            "SELECT * FROM hour_entries WHERE student_id = ? AND status = 'approved'"
            " ORDER BY service_date ASC",
            (account["id"],),
        ).fetchall()
        buffer = io.StringIO()
        writer = csv.writer(buffer)
        writer.writerow(
            ["Date", "Hours", "Category", "Organization", "Description",
             "Supervisor", "Supervisor contact", "Status"]
        )
        for row in rows:
            writer.writerow(
                [row["service_date"], row["hours"], row["category"], row["organization"],
                 row["description"], row["verifier_name"], row["verifier_contact"], "Approved"]
            )
        return buffer.getvalue()

    # --------------------------------------------------------- invite codes

    def create_codes(self, token, payload):
        """One code per named student, so a code always identifies who it is for.

        Takes a list, because a cohort is eighty-odd students and issuing them
        one at a time is how a counselor ends up not using the app.
        """
        counselor = self.staff_or_403(token)
        students = payload.get("students")
        if not isinstance(students, list) or not students:
            raise HttpError(
                400,
                "Send a students list, each with firstName, lastName and grade",
                "students_missing",
            )
        if len(students) > 400:
            raise HttpError(400, "That is more than 400 students in one go", "too_many")

        cleaned = []
        for index, student in enumerate(students):
            if not isinstance(student, dict):
                raise HttpError(400, f"Student {index + 1} is not valid", "bad_student")
            first = str(student.get("firstName", "")).strip()
            last = str(student.get("lastName", "")).strip()
            grade = student.get("grade")
            if not first or not last:
                raise HttpError(
                    400, f"Student {index + 1} needs a first and last name", "name_missing"
                )
            try:
                grade = int(grade)
            except (TypeError, ValueError):
                raise HttpError(400, f"Student {index + 1} needs a grade", "bad_grade")
            if grade not in (9, 10, 11, 12):
                raise HttpError(
                    400, f"{first} {last}: grade must be 9, 10, 11 or 12", "bad_grade"
                )
            cleaned.append((first, last, grade))

        days = int(payload.get("expiresInDays", db.CODE_TTL_DAYS))
        now = time.time()
        expires = now + days * 86400

        created = []
        for first, last, grade in cleaned:
            for _attempt in range(10):
                code = db.generate_code()
                exists = self.conn.execute(
                    "SELECT 1 FROM invite_codes WHERE code = ?", (code,)
                ).fetchone()
                if not exists:
                    break
            else:
                raise HttpError(500, "Could not generate a unique code", "code_exhausted")
            self.conn.execute(
                "INSERT INTO invite_codes"
                " (code, issued_by, first_name, last_name, role, grade, created_at, expires_at)"
                " VALUES (?,?,?,?,'student',?,?,?)",
                (code, counselor["id"], first, last, grade, now, expires),
            )
            created.append(
                {
                    "code": code,
                    "firstName": first,
                    "lastName": last,
                    "grade": grade,
                    "state": "outstanding",
                    "createdAt": now,
                    "expiresAt": expires,
                    "redeemedAt": None,
                }
            )
        db.audit(self.conn, counselor["id"], "counselor", "codes.issued",
                 after={"count": len(created)})
        return {"codes": created, "count": len(created), "expiresAt": expires}

    def list_codes(self, token, query):
        self.staff_or_403(token)
        rows = self.conn.execute(
            "SELECT * FROM invite_codes ORDER BY created_at DESC"
        ).fetchall()
        now = time.time()
        out = []
        for row in rows:
            if row["redeemed_by"]:
                state = "redeemed"
            elif row["revoked_at"]:
                state = "revoked"
            elif row["expires_at"] < now:
                state = "expired"
            else:
                state = "outstanding"
            if query.get("state", [None])[0] and query["state"][0] != state:
                continue
            out.append(
                {
                    "code": row["code"],
                    "firstName": row["first_name"],
                    "lastName": row["last_name"],
                    "role": row["role"],
                    "grade": row["grade"],
                    "state": state,
                    "createdAt": row["created_at"],
                    "expiresAt": row["expires_at"],
                    "redeemedAt": row["redeemed_at"],
                }
            )
        return {
            "codes": out,
            "outstanding": sum(1 for c in out if c["state"] == "outstanding"),
            "redeemed": sum(1 for c in out if c["state"] == "redeemed"),
        }

    def revoke_code(self, token, code):
        counselor = self.staff_or_403(token)
        row = self.conn.execute(
            "SELECT * FROM invite_codes WHERE code = ?", (code.upper(),)
        ).fetchone()
        if row is None:
            raise HttpError(404, "No such code", "not_found")
        if row["redeemed_by"]:
            raise HttpError(409, "That code has already been used", "code_used")
        self.conn.execute(
            "UPDATE invite_codes SET revoked_at = ? WHERE code = ?", (time.time(), code.upper())
        )
        db.audit(self.conn, counselor["id"], "counselor", "code.revoked",
                 after={"code": code.upper()})
        return {"ok": True}

    # ----------------------------------------------------------------- staff

    def staff_json(self, row):
        return {
            "id": row["id"],
            "displayName": row["display_name"],
            "lastName": row["last_name"],
            "username": row["username"],
            "role": row["role"],
            "createdAt": row["created_at"],
        }

    def list_staff(self, token):
        """Everyone with staff access, plus staff invites not yet redeemed.

        Readable by any staff member: a manager should be able to see who else
        can approve hours. Only an admin can change any of it.
        """
        account = self.staff_or_403(token)
        rows = self.conn.execute(
            "SELECT * FROM accounts WHERE role IN ('manager','admin')"
            " AND deleted_at IS NULL ORDER BY role DESC, last_name COLLATE NOCASE"
        ).fetchall()
        pending = self.conn.execute(
            "SELECT * FROM invite_codes WHERE role IN ('manager','admin')"
            " AND redeemed_by IS NULL AND revoked_at IS NULL"
            " ORDER BY created_at DESC"
        ).fetchall()
        now = time.time()
        return {
            "staff": [self.staff_json(r) for r in rows],
            "pending": [
                {
                    "code": r["code"],
                    "firstName": r["first_name"],
                    "lastName": r["last_name"],
                    "role": r["role"],
                    "expiresAt": r["expires_at"],
                    "expired": r["expires_at"] < now,
                }
                for r in pending
            ],
            "admins": sum(1 for r in rows if r["role"] == "admin"),
            "canManage": account["role"] == "admin",
        }

    def invite_staff(self, token, payload):
        """Issue a code that creates a manager or an admin.

        This is the only way a staff account comes into being after the first
        one, and only an admin can do it. The invited person sets their own
        password when they redeem it, so whoever invited them never knows it.
        """
        admin = self.admin_or_403(token)
        first = str(payload.get("firstName", "")).strip()
        last = str(payload.get("lastName", "")).strip()
        role = payload.get("role", "manager")

        if not first or not last:
            raise HttpError(400, "A first and last name are required", "name_missing")
        if role not in self.STAFF_ROLES:
            raise HttpError(400, "role must be manager or admin", "bad_role")

        days = int(payload.get("expiresInDays", db.CODE_TTL_DAYS))
        now = time.time()
        expires = now + days * 86400

        for _attempt in range(10):
            code = db.generate_code()
            if not self.conn.execute(
                "SELECT 1 FROM invite_codes WHERE code = ?", (code,)
            ).fetchone():
                break
        else:
            raise HttpError(500, "Could not generate a unique code", "code_exhausted")

        self.conn.execute(
            "INSERT INTO invite_codes"
            " (code, issued_by, first_name, last_name, role, grade, created_at, expires_at)"
            " VALUES (?,?,?,?,?,NULL,?,?)",
            (code, admin["id"], first, last, role, now, expires),
        )
        db.audit(self.conn, admin["id"], admin["role"], "staff.invited",
                 after={"role": role, "name": f"{first} {last}", "code": code})
        return {
            "code": code, "firstName": first, "lastName": last,
            "role": role, "expiresAt": expires,
        }

    def set_staff_role(self, token, account_id, payload):
        """Promote a manager to admin, or step an admin back down to manager."""
        admin = self.admin_or_403(token)
        target = self.account_or_404(account_id)
        role = payload.get("role")

        if role not in self.STAFF_ROLES:
            raise HttpError(400, "role must be manager or admin", "bad_role")
        if target["role"] == "student":
            raise HttpError(
                400, "A student account cannot be given staff access", "not_staff"
            )
        if target["role"] == role:
            return {"ok": True, "staff": self.staff_json(target)}

        # The program must always have an owner. Stepping down is allowed, but
        # only once somebody else can let people back in.
        if target["role"] == "admin" and role == "manager" and self.admin_count(
            excluding=target["id"]
        ) == 0:
            raise HttpError(
                409,
                "This is the only admin. Make someone else an admin first, "
                "then step this account down.",
                "last_admin",
            )

        self.conn.execute(
            "UPDATE accounts SET role = ? WHERE id = ?", (role, target["id"])
        )
        db.audit(self.conn, admin["id"], admin["role"], "staff.role_changed",
                 account_id=target["id"],
                 before={"role": target["role"]}, after={"role": role})
        return {"ok": True, "staff": self.staff_json(self.account_or_404(target["id"]))}

    def remove_staff(self, token, account_id):
        """Take away someone's staff access.

        Their past decisions stay exactly where they are. An approval is a
        record of who verified what, and a counselor leaving the district does
        not make the hours they approved any less verified.
        """
        admin = self.admin_or_403(token)
        target = self.account_or_404(account_id)

        if target["role"] not in self.STAFF_ROLES:
            raise HttpError(400, "That account is not staff", "not_staff")
        if target["role"] == "admin" and self.admin_count(excluding=target["id"]) == 0:
            raise HttpError(
                409,
                "This is the only admin. Make someone else an admin first.",
                "last_admin",
            )

        now = time.time()
        anon = f"Removed staff {target['id'][:8]}"
        self.conn.execute(
            "UPDATE accounts SET deleted_at = ?, username = ?, password_hash = '',"
            " password_salt = '' WHERE id = ?",
            (now, f"removed-{target['id']}", target["id"]),
        )
        self.conn.execute("DELETE FROM sessions WHERE account_id = ?", (target["id"],))
        db.audit(self.conn, admin["id"], admin["role"], "staff.removed",
                 account_id=target["id"],
                 before={"role": target["role"], "name": target["display_name"]})
        return {
            "ok": True,
            "removed": target["display_name"],
            "retained": "their past approvals, which remain attributed to them",
            "anonymisedAs": anon,
        }

    # -------------------------------------------------------- password resets

    def issue_password_reset(self, token, payload):
        """Hand someone a one-time code to set a new password.

        No email server stands behind this prototype, so a reset travels the
        same way an invite does: an admin issues it and gives it to the person.
        Issuing one neither reveals nor changes the current password - that only
        happens when the code is redeemed.
        """
        admin = self.admin_or_403(token)
        account_id = str(payload.get("accountId", "")).strip()
        if not account_id:
            raise HttpError(400, "accountId is required", "account_missing")
        target = self.account_or_404(account_id)

        for _attempt in range(10):
            code = db.generate_code()
            if not self.conn.execute(
                "SELECT 1 FROM password_resets WHERE code = ?", (code,)
            ).fetchone():
                break
        else:
            raise HttpError(500, "Could not generate a unique code", "code_exhausted")

        now = time.time()
        expires = now + 2 * 86400
        self.conn.execute(
            "INSERT INTO password_resets (code, account_id, issued_by, created_at, expires_at)"
            " VALUES (?,?,?,?,?)",
            (code, target["id"], admin["id"], now, expires),
        )
        db.audit(self.conn, admin["id"], admin["role"], "password.reset_issued",
                 account_id=target["id"])
        return {
            "code": code,
            "for": target["display_name"],
            "username": target["username"],
            "expiresAt": expires,
        }

    def reset_password(self, payload):
        """Redeem a reset code and set a new password. Unauthenticated by need."""
        code = str(payload.get("code", "")).strip().upper()
        password = str(payload.get("password", ""))
        if not code:
            raise HttpError(400, "Enter the reset code you were given", "code_missing")
        if len(password) < 8:
            raise HttpError(
                400, "A password of at least 8 characters is required", "password_short"
            )

        with self.lock:
            row = self.conn.execute(
                "SELECT * FROM password_resets WHERE code = ?", (code,)
            ).fetchone()
            if row is None:
                raise HttpError(400, "That reset code was not recognised", "code_unknown")
            if row["used_at"] is not None:
                raise HttpError(400, "That reset code has already been used", "code_used")
            if row["expires_at"] < time.time():
                raise HttpError(400, "That reset code has expired", "code_expired")

            target = self.account_or_404(row["account_id"])
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                cursor = self.conn.execute(
                    "UPDATE password_resets SET used_at = ? WHERE code = ? AND used_at IS NULL",
                    (time.time(), code),
                )
                if cursor.rowcount != 1:
                    raise HttpError(400, "That reset code has already been used", "code_used")
                db.set_password(self.conn, target["id"], password)
                # Every existing session is cut: a password reset exists for the
                # case where someone else may have had the old one.
                self.conn.execute(
                    "DELETE FROM sessions WHERE account_id = ?", (target["id"],)
                )
                db.audit(self.conn, target["id"], target["role"], "password.reset_used",
                         account_id=target["id"])
                self.conn.execute("COMMIT")
            except Exception:
                self.conn.execute("ROLLBACK")
                raise

        return {"ok": True, "username": target["username"]}

    # ------------------------------------------------------------- checklist

    def get_checklist(self, token):
        account = self.account_or_401(token)
        items = [
            item
            for item in self.requirements["checklist"]
            if account["grade"] in item["appliesToGrades"]
        ]
        state = {
            row["item_id"]: bool(row["checked"])
            for row in self.conn.execute(
                "SELECT item_id, checked FROM checklist_state WHERE account_id = ?",
                (account["id"],),
            )
        }
        return {
            "items": [
                {
                    "id": item["id"],
                    "title": item["title"],
                    "page": item["page"],
                    "checked": state.get(item["id"], False),
                }
                for item in items
            ]
        }

    def set_checklist(self, token, item_id, payload):
        account = self.account_or_401(token)
        known = {item["id"] for item in self.requirements["checklist"]}
        if item_id not in known:
            raise HttpError(404, "No such checklist item", "not_found")
        checked = 1 if payload.get("checked") else 0
        self.conn.execute(
            "INSERT INTO checklist_state (account_id, item_id, checked, updated_at)"
            " VALUES (?,?,?,?) ON CONFLICT(account_id, item_id)"
            " DO UPDATE SET checked = excluded.checked, updated_at = excluded.updated_at",
            (account["id"], item_id, checked, time.time()),
        )
        return {"ok": True, "id": item_id, "checked": bool(checked)}


# ------------------------------------------------------------------- routing

ROUTES = [
    ("POST",   r"^/auth/redeem$",            "redeem"),
    ("POST",   r"^/auth/login$",             "login"),
    ("POST",   r"^/auth/logout$",            "logout"),
    ("GET",    r"^/me$",                     "me"),
    ("POST",   r"^/me/role$",                "set_role"),
    ("DELETE", r"^/me$",                     "delete_me"),
    ("GET",    r"^/entries$",                "list_entries"),
    ("POST",   r"^/entries$",                "create_entry"),
    ("PATCH",  r"^/entries/([0-9a-f]+)$",    "update_entry"),
    ("DELETE", r"^/entries/([0-9a-f]+)$",    "delete_entry"),
    ("POST",   r"^/entries/([0-9a-f]+)/submit$",  "submit_entry"),
    ("POST",   r"^/entries/([0-9a-f]+)/decision$", "decide_entry"),
    ("GET",    r"^/entries/([0-9a-f]+)/history$", "entry_history"),
    ("GET",    r"^/progress$",               "progress"),
    ("GET",    r"^/roster$",                 "roster"),
    ("GET",    r"^/roster\.csv$",            "roster_csv"),
    ("GET",    r"^/export\.csv$",            "student_export_csv"),
    ("POST",   r"^/invite-codes$",           "create_codes"),
    ("GET",    r"^/invite-codes$",           "list_codes"),
    ("GET",    r"^/invite-codes/lookup$",    "lookup_code"),
    ("GET",    r"^/staff$",                  "list_staff"),
    ("POST",   r"^/staff/invites$",          "invite_staff"),
    ("POST",   r"^/staff/([0-9a-f-]+)/role$", "set_staff_role"),
    ("DELETE", r"^/staff/([0-9a-f-]+)$",     "remove_staff"),
    ("POST",   r"^/password-resets$",        "issue_password_reset"),
    ("POST",   r"^/auth/reset$",             "reset_password"),
    ("DELETE", r"^/invite-codes/([A-Z0-9]+)$", "revoke_code"),
    ("GET",    r"^/checklist$",              "get_checklist"),
    ("PUT",    r"^/checklist/([a-z0-9-]+)$", "set_checklist"),
    ("GET",    r"^/health$",                 "health"),
]

NEEDS_TOKEN = {
    "logout", "me", "set_role", "delete_me", "list_entries", "create_entry",
    "update_entry", "delete_entry", "submit_entry", "decide_entry", "entry_history",
    "progress", "roster", "roster_csv", "student_export_csv", "create_codes",
    "list_codes", "revoke_code", "get_checklist", "set_checklist",
    "list_staff", "invite_staff", "set_staff_role", "remove_staff",
    "issue_password_reset",
}
TAKES_PAYLOAD = {
    "redeem", "login", "set_role", "create_entry", "update_entry", "decide_entry",
    "create_codes", "set_checklist", "invite_staff", "set_staff_role",
    "issue_password_reset", "reset_password",
}
TAKES_QUERY = {"list_entries", "roster", "roster_csv", "list_codes", "lookup_code"}
CSV_ROUTES = {"roster_csv", "student_export_csv"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    service = None

    def log_message(self, fmt, *args):
        if os.environ.get("GREENCORD_VERBOSE"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, status, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        # This prototype serves only its own iOS client, so nothing is shared
        # cross-origin and no browser is ever pointed at it.
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def _dispatch(self, method):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query)

        for route_method, pattern, name in ROUTES:
            if route_method != method:
                continue
            match = re.match(pattern, parsed.path)
            if not match:
                continue
            return self._invoke(name, match.groups(), query)

        self._send(404, json.dumps({"error": "no such endpoint", "code": "not_found"}))

    def _invoke(self, name, groups, query):
        service = Handler.service
        if name == "health":
            return self._send(200, json.dumps({"ok": True, "service": "greencord"}))

        auth = self.headers.get("Authorization", "")
        token = auth[7:].strip() if auth.lower().startswith("bearer ") else None

        payload = {}
        if name in TAKES_PAYLOAD:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            try:
                payload = json.loads(raw or b"{}")
            except ValueError:
                return self._send(
                    400, json.dumps({"error": "body must be JSON", "code": "bad_json"})
                )
            if not isinstance(payload, dict):
                return self._send(
                    400, json.dumps({"error": "body must be a JSON object", "code": "bad_json"})
                )

        args = []
        if name in NEEDS_TOKEN:
            args.append(token)
        args.extend(groups)
        if name in TAKES_PAYLOAD:
            args.append(payload)
        elif name in TAKES_QUERY:
            args.append(query)

        try:
            with service.lock:
                result = getattr(service, name)(*args)
        except HttpError as exc:
            return self._send(
                exc.status, json.dumps({"error": exc.message, "code": exc.code})
            )
        except Exception as exc:  # noqa: BLE001 - never leak internals to a client
            sys.stderr.write(f"internal error in {name}: {exc!r}\n")
            return self._send(
                500, json.dumps({"error": "internal error", "code": "internal"})
            )

        if name in CSV_ROUTES:
            return self._send(200, result, "text/csv; charset=utf-8")
        return self._send(200, json.dumps(result))

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PATCH(self):
        self._dispatch("PATCH")

    def do_PUT(self):
        self._dispatch("PUT")

    def do_DELETE(self):
        self._dispatch("DELETE")


def build_server(db_path, port, certfile, keyfile, bind="127.0.0.1"):
    Handler.service = Service(db_path)
    httpd = ThreadingHTTPServer((bind, port), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile, keyfile)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    return httpd


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default=os.path.join(ROOT, "build", "greencord.db"))
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--cert", default=os.path.join(ROOT, "build", "certs", "server.crt"))
    parser.add_argument("--key", default=os.path.join(ROOT, "build", "certs", "server.key"))
    parser.add_argument(
        "--bind",
        default="127.0.0.1",
        help="Address to listen on. The default accepts connections from this "
             "machine only. Pass 0.0.0.0 to let a phone on the same network "
             "reach it - only do that on a network you trust, because the "
             "prototype's data is real to anyone who can sign in.",
    )
    args = parser.parse_args()

    os.makedirs(os.path.dirname(args.db), exist_ok=True)
    if not (os.path.exists(args.cert) and os.path.exists(args.key)):
        raise SystemExit(
            f"missing TLS certificate at {args.cert}. Run tools/gen-certs.sh first."
        )
    httpd = build_server(args.db, args.port, args.cert, args.key, bind=args.bind)
    print(f"greencord backend listening on https://{args.bind}:{args.port}  db={args.db}")
    if args.bind != "127.0.0.1":
        print("  reachable from other devices on this network")
    sys.stdout.flush()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
