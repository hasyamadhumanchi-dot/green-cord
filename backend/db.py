"""Storage layer for the Green Cord prototype backend.

The production target is Postgres with row-level security; that schema lives in
`backend/migrations/0001_init.sql` and is what deploys to Supabase. This module is
the prototype's runtime store: the same tables and the same constraints expressed
in SQLite, so the server can run on a laptop with no database to install.

Everything security-relevant is enforced here and in server.py, never in the
client. The iOS app holds a session token and nothing else.
"""
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time

# Codes a student has to copy off a paper slip: no 0/O/1/I/L, no vowels that make
# accidental words.
CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
CODE_LENGTH = 8
CODE_TTL_DAYS = 30
CODE_BATCH_SIZE = 40

SCHEMA = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- Three roles.
--
--   student  logs their own hours and sees nothing else
--   manager  reviews hours, manages students and codes
--   admin    everything a manager can, plus creating and removing staff
--
-- There is always at least one admin: the program has to have an owner, and the
-- guards in server.py refuse any change that would leave none.
CREATE TABLE IF NOT EXISTS accounts (
    id            TEXT PRIMARY KEY,
    role          TEXT NOT NULL CHECK (role IN ('student', 'manager', 'admin')),
    display_name  TEXT NOT NULL,
    last_name     TEXT NOT NULL,
    grade         INTEGER CHECK (grade IS NULL OR grade BETWEEN 9 AND 12),
    username      TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    password_salt TEXT NOT NULL,
    created_at    REAL NOT NULL,
    deleted_at    REAL,
    -- A student account must carry a grade; a staff account must not.
    CHECK ((role = 'student' AND grade IS NOT NULL)
        OR (role IN ('manager', 'admin') AND grade IS NULL))
);

CREATE TABLE IF NOT EXISTS sessions (
    token      TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id),
    created_at REAL NOT NULL,
    expires_at REAL NOT NULL
);

-- One code system for everyone. A student code carries a grade; a staff code
-- carries a role instead, and only an admin can issue one.
CREATE TABLE IF NOT EXISTS invite_codes (
    code        TEXT PRIMARY KEY,
    issued_by   TEXT NOT NULL REFERENCES accounts(id),
    -- The person this code was made for. Whoever issues it names them, so the
    -- roster exists before anyone signs up and a code can never be used by
    -- whoever happens to find it.
    first_name  TEXT NOT NULL,
    last_name   TEXT NOT NULL,
    role        TEXT NOT NULL DEFAULT 'student'
                CHECK (role IN ('student', 'manager', 'admin')),
    grade       INTEGER CHECK (grade IS NULL OR grade BETWEEN 9 AND 12),
    created_at  REAL NOT NULL,
    expires_at  REAL NOT NULL,
    revoked_at  REAL,
    redeemed_by TEXT REFERENCES accounts(id),
    redeemed_at REAL,
    CHECK ((role = 'student' AND grade IS NOT NULL)
        OR (role IN ('manager', 'admin') AND grade IS NULL))
);

-- A one-time code that lets someone set a new password.
--
-- There is no email server behind this prototype, so a reset is handed over the
-- same way an invite is: an admin issues one and gives it to the person. The
-- code is single use and short lived, and issuing one never reveals or changes
-- the existing password until it is redeemed.
CREATE TABLE IF NOT EXISTS password_resets (
    code       TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES accounts(id),
    issued_by  TEXT NOT NULL REFERENCES accounts(id),
    created_at REAL NOT NULL,
    expires_at REAL NOT NULL,
    used_at    REAL
);

CREATE TABLE IF NOT EXISTS hour_entries (
    id               TEXT PRIMARY KEY,
    student_id       TEXT NOT NULL REFERENCES accounts(id),
    service_date     TEXT NOT NULL,
    hours            REAL NOT NULL CHECK (hours > 0),
    category         TEXT NOT NULL,
    organization     TEXT NOT NULL,
    description      TEXT NOT NULL,
    verifier_name    TEXT NOT NULL,
    verifier_contact TEXT NOT NULL,
    evidence_url     TEXT,
    counselor_entered INTEGER NOT NULL DEFAULT 0,
    status           TEXT NOT NULL CHECK (status IN
                        ('draft','submitted','approved','rejected','revision_requested')),
    created_at       REAL NOT NULL,
    updated_at       REAL NOT NULL,
    submitted_at     REAL,
    decided_at       REAL
);
CREATE INDEX IF NOT EXISTS idx_entries_student ON hour_entries(student_id);
CREATE INDEX IF NOT EXISTS idx_entries_status  ON hour_entries(status);

CREATE TABLE IF NOT EXISTS approvals (
    id         TEXT PRIMARY KEY,
    entry_id   TEXT NOT NULL REFERENCES hour_entries(id),
    actor_id   TEXT NOT NULL REFERENCES accounts(id),
    action     TEXT NOT NULL CHECK (action IN
                  ('approve','reject','request_revision','revise')),
    note       TEXT NOT NULL DEFAULT '',
    created_at REAL NOT NULL
);

-- Append-only. The triggers below make UPDATE and DELETE impossible, so an
-- approval's original values stay retrievable even after a counselor revision.
CREATE TABLE IF NOT EXISTS audit_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    at          REAL NOT NULL,
    actor_id    TEXT,
    actor_role  TEXT,
    action      TEXT NOT NULL,
    entry_id    TEXT,
    account_id  TEXT,
    before_json TEXT,
    after_json  TEXT
);

CREATE TRIGGER IF NOT EXISTS audit_log_no_update
BEFORE UPDATE ON audit_log
BEGIN
    SELECT RAISE(ABORT, 'audit_log is append-only');
END;

CREATE TRIGGER IF NOT EXISTS audit_log_no_delete
BEFORE DELETE ON audit_log
BEGIN
    SELECT RAISE(ABORT, 'audit_log is append-only');
END;

CREATE TABLE IF NOT EXISTS checklist_state (
    account_id TEXT NOT NULL REFERENCES accounts(id),
    item_id    TEXT NOT NULL,
    checked    INTEGER NOT NULL DEFAULT 0,
    updated_at REAL NOT NULL,
    PRIMARY KEY (account_id, item_id)
);
"""


def connect(path):
    # The HTTP server handles each request on its own thread. Every database
    # call is serialised by Service.lock, so one shared connection is both safe
    # and simpler than a connection pool at this size.
    conn = sqlite3.connect(path, timeout=15, isolation_level=None, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init(path):
    conn = connect(path)
    conn.executescript(SCHEMA)
    return conn


def new_id():
    return secrets.token_hex(16)


def hash_password(password, salt=None):
    salt = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 120_000)
    return digest.hex(), salt


def verify_password(password, stored_hash, salt):
    candidate, _ = hash_password(password, salt)
    return hmac.compare_digest(candidate, stored_hash)


def set_password(conn, account_id, password):
    """Replace an account's password. Used only by a redeemed reset code."""
    password_hash, salt = hash_password(password)
    conn.execute(
        "UPDATE accounts SET password_hash = ?, password_salt = ? WHERE id = ?",
        (password_hash, salt, account_id),
    )


def generate_code():
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))


def audit(conn, actor_id, actor_role, action, entry_id=None, account_id=None,
          before=None, after=None):
    conn.execute(
        "INSERT INTO audit_log (at, actor_id, actor_role, action, entry_id, account_id,"
        " before_json, after_json) VALUES (?,?,?,?,?,?,?,?)",
        (
            time.time(),
            actor_id,
            actor_role,
            action,
            entry_id,
            account_id,
            json.dumps(before, sort_keys=True) if before is not None else None,
            json.dumps(after, sort_keys=True) if after is not None else None,
        ),
    )


def create_account(conn, role, display_name, last_name, grade, username, password):
    password_hash, salt = hash_password(password)
    account_id = new_id()
    conn.execute(
        "INSERT INTO accounts (id, role, display_name, last_name, grade, username,"
        " password_hash, password_salt, created_at) VALUES (?,?,?,?,?,?,?,?,?)",
        (account_id, role, display_name, last_name, grade, username,
         password_hash, salt, time.time()),
    )
    return account_id


def issue_session(conn, account_id, ttl_seconds=12 * 3600):
    token = secrets.token_urlsafe(32)
    now = time.time()
    conn.execute(
        "INSERT INTO sessions (token, account_id, created_at, expires_at) VALUES (?,?,?,?)",
        (token, account_id, now, now + ttl_seconds),
    )
    return token


def account_for_token(conn, token):
    if not token:
        return None
    row = conn.execute(
        "SELECT a.* FROM sessions s JOIN accounts a ON a.id = s.account_id"
        " WHERE s.token = ? AND s.expires_at > ? AND a.deleted_at IS NULL",
        (token, time.time()),
    ).fetchone()
    return row
