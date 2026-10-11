#!/usr/bin/env python3
"""Access rules, checked against a real Postgres database.

The SQLite suite proves the server enforces the rules. This proves the database
does, which is what matters if anything ever reaches it another way - a direct
connection, a misconfigured client, a future web front end.

Needs 0001 and 0002 applied, and a connection string:

    GC_DSN=postgresql://... python3 backend/tests/test_postgres_rls.py

It deletes every row in the schema, so point it at a test database.
"""
import os, sys, psycopg
DSN = os.environ["GC_DSN"]

def as_account(cur, account_id):
    cur.execute("select set_config('greencord.account_id', %s, true)", (str(account_id or ''),))

with psycopg.connect(DSN, connect_timeout=25) as conn:
    conn.autocommit = True
    with conn.cursor() as cur:
        # Clean slate, as the owner (RLS does not apply to the table owner).
        # TRUNCATE rather than DELETE: audit_log refuses row deletes by design,
        # and truncation bypasses row triggers.
        cur.execute("truncate approvals, audit_log, hour_entries, checklist_state,"
                    " password_resets, invite_codes, sessions, accounts"
                    " restart identity cascade")

        def mk(role, name, grade, username):
            cur.execute("""insert into accounts (role, display_name, last_name, grade,
                           username, password_hash, password_salt)
                           values (%s,%s,'Test',%s,%s,'h','s') returning id""",
                        (role, name, grade, username))
            return cur.fetchone()[0]

        admin = mk('admin', 'The Admin', None, 'admin')
        mgr   = mk('manager', 'A Manager', None, 'manager')
        a     = mk('student', 'Student A', 11, 'studenta')
        b     = mk('student', 'Student B', 11, 'studentb')

        def entry(student, status='draft'):
            cur.execute("""insert into hour_entries (student_id, service_date, hours,
                category, organization, description, verifier_name, verifier_contact, status)
                values (%s,'2026-09-01',5,'community','Food Bank','Sorted','Sup','s@e.org',%s)
                returning id""", (student, status))
            return cur.fetchone()[0]

        ea, eb = entry(a), entry(b)
        approved = entry(a, 'approved')

results = []
with psycopg.connect(DSN, connect_timeout=25) as conn:
    with conn.cursor() as cur:
        def check(label, account, sql, expect, args=()):
            cur.execute("begin")
            cur.execute('set local role "authenticated"')
            as_account(cur, account)
            try:
                cur.execute(sql, args)
                got = cur.fetchone()[0] if cur.description else None
                ok = (got == expect)
                results.append((ok, f"{label}: {got} (expected {expect})"))
            except Exception as e:
                results.append((expect == 'ERROR',
                                f"{label}: refused - {str(e).splitlines()[0][:44]}"))
            cur.execute("rollback")

        cur.execute("select id from accounts where username='studenta'"); a = cur.fetchone()[0]
        cur.execute("select id from accounts where username='studentb'"); b = cur.fetchone()[0]
        cur.execute("select id from accounts where username='manager'");  mgr = cur.fetchone()[0]
        cur.execute("select id from accounts where username='admin'");    admin = cur.fetchone()[0]

        check("nobody signed in sees entries",     None,  "select count(*) from hour_entries", 0)
        check("nobody signed in sees accounts",    None,  "select count(*) from accounts", 0)
        check("student A sees only their own",     a,     "select count(*) from hour_entries", 2)
        check("student B sees only their own",     b,     "select count(*) from hour_entries", 1)
        check("student A cannot see B's entry",    a,
              "select count(*) from hour_entries where student_id = %s", 0, (b,))
        check("manager sees every entry",          mgr,   "select count(*) from hour_entries", 3)
        check("admin sees every entry",            admin, "select count(*) from hour_entries", 3)
        check("student sees only their own account", a,   "select count(*) from accounts", 1)
        check("manager sees every account",        mgr,   "select count(*) from accounts", 4)
        check("student cannot read invite codes",  a,     "select count(*) from invite_codes", 0)
        check("student cannot read password resets", a,   "select count(*) from password_resets", 0)
        check("manager cannot read password resets", mgr, "select count(*) from password_resets", 0)
        check("admin can read password resets",    admin, "select count(*) from password_resets", 0)

        # The permanence rule, and self-promotion.
        cur.execute("begin"); cur.execute('set local role "authenticated"'); as_account(cur, a)
        cur.execute("update hour_entries set hours = 99 where status = 'approved'")
        results.append((cur.rowcount == 0,
                        f"student editing an approved entry changed {cur.rowcount} rows (expected 0)"))
        cur.execute("rollback")

        cur.execute("begin"); cur.execute('set local role "authenticated"'); as_account(cur, a)
        try:
            cur.execute("update accounts set role = 'admin' where id = %s", (a,))
            results.append((False, "student promoted themselves - LEAK"))
        except Exception as e:
            results.append((True, f"student self-promotion refused: {str(e).splitlines()[0][:44]}"))
        cur.execute("rollback")

for ok, line in results:
    print(f"  {'PASS' if ok else 'FAIL'}  {line}")
print(f"\n  {sum(1 for ok,_ in results if ok)}/{len(results)} passed")

sys.exit(0 if all(ok for ok, _ in results) else 1)
