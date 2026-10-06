# Runbook

Operating the Green Cord backend: starting it, provisioning the counselor,
issuing invite codes, and backing up the records.

Everything here is for the **prototype** backend. The production target is
Supabase; where the two differ, both are given.

---

## Starting the server

```bash
tools/gen-certs.sh                                   # once - self-signed TLS cert
python3 backend/server.py --db build/greencord.db --port 8443
```

It listens on `https://127.0.0.1:8443`. It will not start without a certificate,
and it does not listen on plain HTTP at all — a request to `http://` on that port
fails at the TLS handshake, which is asserted by the backend test suite.

The certificate is self-signed and lives in `build/certs/`, which is not
committed. In production, TLS is Supabase's.

Check it is alive:

```bash
curl -sk https://127.0.0.1:8443/health
# {"ok": true, "service": "greencord"}
```

---

## Who can do what

| | Student | Manager | Admin |
| --- | :-: | :-: | :-: |
| Log their own hours | yes | | |
| Review, approve, reject hours | | yes | yes |
| Add students, issue invite codes | | yes | yes |
| See the roster and export it | | yes | yes |
| Log hours on a student's behalf | | yes | yes |
| See who else has staff access | | yes | yes |
| **Add or remove staff** | | | **yes** |
| **Change someone's role** | | | **yes** |
| **Issue a password reset** | | | **yes** |

There is always at least one admin. The server refuses any change that would
leave none — demoting the last admin, or removing them, both fail with a message
saying so. That guard is what stops the program being stranded.

Nobody can give themselves staff access. Role changes are an admin action on the
server; a student or manager calling the role endpoint gets a 403 and the
attempt is written to the audit log.

---

## Adding staff

**In the app**, as an admin: **Home → Staff & access → Add someone.** Enter their
name, choose Manager or Admin, and the app shows a code to give them. They enter
it on the welcome screen under **Create Account** and set their own password, so
nobody else ever knows it.

**Over the API:**

```bash
curl -sk -X POST https://127.0.0.1:8443/staff/invites \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"firstName": "Sam", "lastName": "Okafor", "role": "manager"}'
```

Staff codes use the same alphabet and expiry as student codes: 8 characters,
30 days, single use.

---

## Handing the program over

The sequence matters. Promote first, then step down — the reverse is refused,
because it would briefly leave no admin.

1. **Staff & access → Add someone**, role **Admin**, for whoever is taking over.
2. They redeem the code and sign in.
3. The outgoing admin taps **Make manager** on themselves, or **Remove** once
   there is another admin.

Their past approvals stay exactly as they are, still recorded under their name.
An approval is the record of who verified those hours, so it survives them
leaving the district.

If the outgoing admin has already gone and nobody else is an admin, recover from
the command line:

```bash
sqlite3 build/greencord.db \
  "UPDATE accounts SET role = 'admin' WHERE username = 'their.username';"
```

On Supabase the equivalent is one row in the table editor, or:

```sql
UPDATE accounts SET role = 'admin', grade = NULL WHERE username = 'their.username';
```

---

## Resetting a password

Nobody can read a password, including you — they are hashed with PBKDF2. A reset
replaces it instead.

**In the app**, as an admin: **Staff & access → Reset password** beside the
person. A code appears. Give it to them; they enter it on the welcome screen
under **Log In → Forgot your password?** and choose a new one.

Redeeming a reset signs that account out everywhere, because a reset exists for
the case where somebody else may have had the old password. The code works once
and lasts two days.

**Over the API:**

```bash
curl -sk -X POST https://127.0.0.1:8443/password-resets \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"accountId": "<id from /staff>"}'
```

**If the only admin is locked out**, nobody in the app can help them. Reset it
server-side:

```bash
python3 tools/provision-counselor.py --db build/greencord.db \
  --username <their username> --force
```

---

## Provisioning the counselor

**There is no way to create a counselor through the app.** No HTTP endpoint
creates one, and no endpoint changes an account's role — a student who calls
`POST /me/role` gets a 403 and the attempt is written to the audit log. This is
deliberate and is covered by two tests in the backend suite.

The counselor account is created by an operator, server-side:

```bash
python3 tools/provision-counselor.py \
  --db build/greencord.db \
  --name "Green Cord Coordinator" \
  --username counselor
# prompts for a password
```

It refuses if a counselor already exists; pass `--force` to replace one.

**In production (Supabase)**, the equivalent is: have the person sign up
normally, then run one statement as the operator:

```sql
UPDATE accounts SET role = 'counselor', grade = NULL WHERE id = '<their uuid>';
```

Nothing reachable from a client can do that. The `accounts_guard` trigger in
`backend/migrations/0001_init.sql` raises an exception on any self-initiated role
change.

---

## Issuing invite codes

Codes are the only way to create an account. Each one is single use, belongs to
one named student, carries their grade, and expires.

**From the app:** sign in as the counselor → **Students & invite codes**. Add a
student by first name, last name and grade, or tap **Add a whole list instead**
and paste a class list — one student per line as `First Last, grade`, which is
what a spreadsheet column pastes as. Each student gets their own code, shown
beside their name and exportable as a CSV to print or read out.

Students who have a code but have not signed up yet are listed under **Not
signed up yet**, each with a **Revoke** button, and appear on the roster marked
**Not joined**.

**From the command line:**

```bash
curl -sk -X POST https://127.0.0.1:8443/invite-codes \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"students": [{"firstName": "Jordan", "lastName": "Martinez", "grade": 11}]}'
```

Defaults: **8 characters, 30-day expiry, batches of 40.**

The alphabet is `23456789ABCDEFGHJKMNPQRSTUVWXYZ` — no `0`, `O`, `1`, `I` or `L`.
A student copying a code off a paper slip cannot confuse a zero for an O, which
is the single most common way a handwritten code fails.

**Revoking:** a code that has not been redeemed can be cancelled, after which
redemption is refused. A code that has already been used cannot be revoked — the
account exists, and deleting the account is the operation for that.

**Operational advice:** issue a batch per grade at the start of the year, print
them on slips, and hand them out at a club meeting. Codes are useless once
redeemed, so a lost slip costs one code rather than a security incident. Revoke
the leftovers at the enrollment deadline (1 October, handbook page 5).

---

## Backing up

SQLite's `.backup` is transactionally consistent, so this is safe while the
server is running.

```bash
tools/backup-db.sh build/greencord.db build/backups
```

It writes `greencord-<UTC timestamp>.db`, runs `PRAGMA integrity_check` on the
result, and prints its SHA-256.

**Schedule it.** For the prototype, a cron entry is enough:

```cron
# Every night at 02:00
0 2 * * * cd /path/to/greencord && tools/backup-db.sh >> build/backups/log 2>&1
```

**In production (Supabase)**, daily automated backups come with the platform.
Retention depends on the plan — on the free tier it is 7 days, which is **not
enough for a permanent academic record**. This is called out in RELEASE.md as a
decision the counselor has to make before real data is entered.

### Restoring

```bash
tools/restore-db.sh build/backups/greencord-20260920T210511Z.db build/greencord.db
```

It verifies the backup's integrity *before* touching the target, copies the
existing database aside first, and then prints the row counts so the restore can
be eyeballed.

### The restore test

Run on 2026-09-20 against the seeded demo database. A backup was taken, every
`hour_entries` row was then deleted to simulate loss, and the backup restored:

```
$ tools/backup-db.sh build/greencord-demo.db build/backups
ok
b3b4d6... build/backups/greencord-20260920T210511Z.db
build/backups/greencord-20260920T210511Z.db

$ sqlite3 build/greencord-demo.db "DELETE FROM hour_entries; DELETE FROM sessions;"
$ sqlite3 build/greencord-demo.db 'SELECT COUNT(*) FROM hour_entries;'
0

$ tools/restore-db.sh build/backups/greencord-20260920T210511Z.db build/greencord-demo.db
==> Verifying the backup
    integrity_check: ok
    existing database copied aside to build/greencord-demo.db.before-restore-20260920T210511Z
==> Restored build/backups/greencord-20260920T210511Z.db -> build/greencord-demo.db
accounts|13
hour_entries|48
audit_log|153
```

All 48 entries and all 153 audit rows came back. **Re-run this after any change
to the schema** — a backup that has never been restored is not a backup.

---

## Seeding a demo environment

```bash
tools/seed-demo.sh --keep-running
```

Builds a fresh database, provisions the counselor, then drives the **live API**
(not the database directly) to create twelve synthetic students spread across
grades 9–12 in four states — nothing logged, partway, pending review, and
complete — plus 40 unredeemed grade-9 codes.

Sign-ins afterwards:

| Who | Username | Password |
| --- | --- | --- |
| Counselor | `counselor` | `counselorpass1` |
| Any demo student | e.g. `alpha.alderwood` | `demopassword1` |

**Every name is invented** — phonetic-alphabet first names and tree-species
surnames. No real student appears anywhere in this repository. These passwords
are demo credentials for a local, throwaway database and must never be reused for
anything real.

---

## Resetting

```bash
rm -f build/greencord-demo.db build/greencord-demo.db-wal build/greencord-demo.db-shm
tools/seed-demo.sh
```

---

## Where the data lives

| Table | What it holds |
| --- | --- |
| `accounts` | One row per student plus the single counselor. Name, last name, grade, username, password hash. |
| `invite_codes` | Code, grade, who issued it, expiry, who redeemed it and when. |
| `hour_entries` | The service record: date, hours, category, organization, description, supervisor name and contact, status. |
| `approvals` | Every counselor decision, with its note. |
| `audit_log` | Append-only. Every create, submit, decision and revision, with the values before and after. |
| `checklist_state` | Which program requirements a student has ticked off. |

`audit_log` cannot be updated or deleted. Triggers in SQLite and rewrite rules in
Postgres both block it, which is what makes an approved entry's original values
retrievable after a counselor correction.

---

## Troubleshooting

**"missing TLS certificate"** — run `tools/gen-certs.sh`.

**The app cannot reach the server** — check `GreenCordBackendURL` in
`GreenCordHandbook/Info.plist`. The simulator reaches the host as `127.0.0.1`. A
physical device cannot reach a laptop's loopback address and needs the machine's
LAN address plus a certificate that covers it.

**A student says their code does not work** — check its state:

```bash
sqlite3 build/greencord.db \
  "SELECT code, grade, redeemed_by, revoked_at,
          datetime(expires_at,'unixepoch') FROM invite_codes WHERE code='ABCD2345';"
```

Redeemed, revoked and expired each produce a different message in the app, so the
student's description of what they saw narrows it down before you look.

**The app shows old handbook text** — it keeps the copy it has until a manifest
offers a strictly newer `contentVersion` whose checksums all match. Check
`tools/validate_manifest.py` against the published directory.
