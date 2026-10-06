#!/usr/bin/env python3
"""Create the first admin account. Operator-side only.

    python3 tools/provision-counselor.py --db build/greencord.db \
        --name "A. Counselor" --username counselor --password '<password>'

This writes to the database directly. There is deliberately no HTTP endpoint
that can create a counselor, and no endpoint that can change an account's role,
so a student account can never become one. In production the equivalent step is
a single UPDATE run against Supabase by the operator:

    UPDATE accounts SET role = 'admin', grade = NULL WHERE id = '<uuid>';

Re-running this is safe: it refuses if an admin already exists.

After this, the admin creates every other staff account from inside the app.
"""
import argparse
import getpass
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "backend"))
import db  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    parser.add_argument("--name", default="Green Cord Coordinator")
    parser.add_argument("--last-name", default="Coordinator")
    parser.add_argument("--username", default="counselor")
    parser.add_argument("--password")
    parser.add_argument("--force", action="store_true",
                        help="replace an existing counselor account")
    args = parser.parse_args()

    password = args.password or getpass.getpass("counselor password: ")
    if len(password) < 8:
        raise SystemExit("password must be at least 8 characters")

    conn = db.init(args.db)
    existing = conn.execute(
        "SELECT id, username FROM accounts WHERE role = 'admin'"
    ).fetchone()
    if existing and not args.force:
        print(f"an admin account already exists: {existing['username']} ({existing['id']})")
        print("pass --force to replace it")
        return 1
    if existing:
        conn.execute("DELETE FROM sessions WHERE account_id = ?", (existing["id"],))
        conn.execute("DELETE FROM accounts WHERE id = ?", (existing["id"],))

    account_id = db.create_account(
        conn, "admin", args.name, args.last_name, None, args.username, password
    )
    db.audit(conn, None, "operator", "counselor.provisioned", account_id=account_id,
             after={"username": args.username})
    print(f"admin account created: {args.username}  id={account_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
