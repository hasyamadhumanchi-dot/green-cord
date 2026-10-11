# Deploying this for real

The prototype runs on a laptop. This is what it would take to run it somewhere
students can actually use it, written for whoever picks this up — including you,
months from now, without the context you have today.

**Read this before buying anything or creating accounts.** The honest summary is
that deployment is a day or two of work, not an afternoon, and the cheap-sounding
option is not the one that works.

---

## What exists today

| Piece | State |
| --- | --- |
| iOS app | Done. Talks to a custom API over HTTPS. |
| API server | `backend/server.py` — complete, 55 tests, **stores data in SQLite** |
| Postgres schema | `backend/migrations/0001_init.sql` — **applied to a real Supabase database and verified**, see below |
| Hosting | None. The server runs on your Mac. |

The app calls endpoints like `POST /auth/login`, `GET /entries`, `GET /roster`,
`POST /staff/invites`. Those are this project's own API, defined in
`backend/server.py`. Nothing else serves them.

---

## What has now been proven

The migration was applied to a live Supabase Postgres 17 database and checked.

| Check | Result |
| --- | --- |
| Migration applies cleanly | yes, all 405 lines |
| Tables created | 7 |
| Tables with row-level security | **7 of 7** |
| Policies | 15 |
| Functions / triggers | 8 / 3 |
| Roles in the enum | `student, manager, admin` |

Then the rules were attacked rather than admired. With two students seeded, one
hour entry each:

| Connecting as | `hour_entries` visible |
| --- | --- |
| `anon` — the key that ships inside the app | **0** |
| `authenticated`, no identity | **0** |
| signed in as student A | **1** — their own, not B's |

The same held for `accounts`, `invite_codes` and `audit_log`. **A student cannot
read another student's hours**, and that is now true of the production schema and
not only of the SQLite server.

This was the largest unknown in the project. It is closed.

---

## The gap this uncovered

The Postgres schema and the Python server **do not share an authentication
model**, and this is the real obstacle to Option A below.

- `accounts.id` in Postgres is `REFERENCES auth.users(id)`. Identity belongs to
  Supabase: no row can exist in `accounts` without a Supabase auth user, and
  every policy is written against `auth.uid()`.
- `backend/db.py` implements its own: `accounts` carries `username`,
  `password_hash` and `password_salt`, and `POST /auth/login` checks them.

The Postgres `accounts` table has no `username` column at all. Pointing the
existing server at this schema fails immediately on sign-in.

So "port the server to Postgres" means choosing one of:

1. **Add `username`, `password_hash`, `password_salt` to the Postgres schema and
   drop the `auth.users` foreign key.** Keeps the server's own auth, and every
   policy's `auth.uid()` must be replaced with the server's session user. The 55
   tests keep their meaning. Simpler, and gives up Supabase's auth entirely.
2. **Move the server onto Supabase auth.** Sign-up, sign-in, password reset and
   invite redemption all go through Supabase. Policies stay as written. More
   work, and the invite-code model — where an admin names a student and the code
   carries their identity — has to be rebuilt on top of Supabase's sign-up flow.

Either is a day or more, and neither is a driver swap. The estimate in the next
section was written before this was discovered and was too optimistic.

---

## The mistake to avoid

**Creating a Supabase project does not deploy this app.**

Supabase gives you a Postgres database, its own authentication, and its own REST
API generated from your tables. The app does not speak any of those. Pointing the
app at a Supabase URL would fail on the first request, because `POST /auth/login`
is not an endpoint Supabase serves.

The Postgres schema in `backend/migrations/` is real and worth keeping — it is
the authoritative statement of the access rules, and the SQLite server mirrors
it. But it is a *specification*, not a running system.

---

## Option A — host the Python server (recommended)

The app keeps working unchanged. This is the shorter path.

**Why it is not trivial:** `backend/db.py` uses SQLite, and hosting platforms
give you a container whose disk is wiped on every redeploy. Shipping as-is would
lose every student's hours on each deploy. So the server has to move to Postgres
first.

### What has to change

1. **Swap the driver.** `backend/db.py` line 16 imports `sqlite3`. Replace with
   `psycopg` (v3). The connection helper is one function, `db.connect()`.

2. **Parameter style.** SQLite uses `?`, Postgres uses `%s`. About 19 call sites
   across `backend/server.py`. Mechanical, but every one has to be right —
   a missed one is a runtime error on a path a test may not cover.

3. **Three SQLite-isms** in `backend/server.py`:
   - `BEGIN IMMEDIATE` (3 uses) → `BEGIN` with `SELECT ... FOR UPDATE`, or rely
     on the `UPDATE ... WHERE redeemed_by IS NULL` lock already in place
   - `COLLATE NOCASE` (3 uses) → `LOWER(...)` or a `citext` column
   - `ON CONFLICT ... DO UPDATE` (1 use) → same syntax in Postgres, verify it
   - `INTEGER PRIMARY KEY AUTOINCREMENT` in the audit table → `BIGSERIAL`

4. **Run the migration.** `backend/migrations/0001_init.sql` against the real
   database. It has never been executed. Budget real time here: 300 lines of
   policies, triggers and `SECURITY DEFINER` functions, and the first run of any
   migration finds problems.

   Note it assumes Supabase's `auth.users` table and `auth.uid()`. On plain
   Postgres, replace `auth.uid()` with your own session-user function — there is
   a comment at the top of the file saying so.

5. **Serve it properly.** `server.py` uses Python's `ThreadingHTTPServer`, which
   is fine for a prototype and not for the open internet. Put it behind
   `gunicorn` or `uvicorn`, and let the platform terminate TLS — delete the
   self-signed certificate handling, which exists only so the laptop prototype
   never speaks plain HTTP.

6. **Point the app at it.** One value:
   `GREENCORD_BACKEND_URL=https://your-host.example.com`, passed to
   `tools/generate_xcodeproj.py`. See `PHONE.md`.

### Where to host

Render, Railway and Fly.io all have free or near-free tiers that fit this. All
three give you a Postgres database alongside the app, so you may not need
Supabase at all. Whichever you pick, the thing that matters is **a database
whose disk survives a redeploy**.

### Effort

A focused day if nothing surprises you. Two is more realistic, because the
migration has never run.

---

## Option B — rewrite the app onto Supabase directly

Delete the Python server. The app talks to Supabase's auth and PostgREST, and
the row-level security policies in `0001_init.sql` become the only enforcement.

This is the better long-term architecture — fewer moving parts, nothing to host,
and the security rules live in one place. It is also several days of work:
`GreenCordHandbook/Backend/RemoteAPI.swift` is written against this project's own
API shape, and every call would change.

The 55 backend tests would no longer apply, which is the real cost. They are the
reason anyone can trust the access rules, and they test the Python server.

**Do not start this unless you have a week and a reason.**

---

## Before any of this: should it be deployed at all?

Deployment means real student records on a server somebody owns. Settle these
first, because they are harder than the code:

1. **Who owns the account** the data sits in, and who pays for it.
2. **Written district authorisation** — see `RELEASE.md`. Running a prototype on
   a laptop is one thing; holding minors' records on hosted infrastructure under
   a personal account is another.
3. **What happens at graduation**, which `RELEASE.md` records as an unanswered
   question with a default implemented.
4. **Who maintains it** once the student who built it leaves.

If those have no answers, the honest move is to leave it as a demonstrated
prototype and hand over this repository. That is a complete piece of work, and
pretending otherwise helps nobody.

---

## If you only do one thing

Decide which authentication model you want — the server's own, or Supabase's —
before writing any code. Everything else follows from it, and doing it in the
wrong order means rewriting the access rules twice.

The schema itself is proven. What is not settled is who owns identity.
