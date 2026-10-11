# Deploying this for real

The prototype runs on a laptop. This is what it takes to run it somewhere
students can actually use it.

**The code side is done.** The server runs on Postgres, all 55 tests pass
against a hosted database, and the access rules were verified there too. What is
left is hosting configuration and the questions about ownership at the end of
this file, which are harder than the code ever was.

---

## What exists today

| Piece | State |
| --- | --- |
| iOS app | Done. Talks to a custom API over HTTPS. |
| API server | `backend/server.py` — runs on **SQLite or Postgres**, 55 tests passing on both |
| Postgres schema | `0001` + `0002` + `0003` — **applied to a real database**, 15 access-rule checks passing |
| Hosting | **None.** This is the remaining work. |

Set `GREENCORD_DATABASE_URL` and the server uses Postgres. Leave it unset and
nothing about the prototype changes.

```bash
# the prototype, unchanged
tools/demo-start.sh

# the same server, on Postgres
GREENCORD_DATABASE_URL=postgresql://... python3 backend/server.py --port 8443
```

---

## Putting it on a host

Any platform that runs a Python process and gives you a Postgres database will
do — Render, Railway and Fly.io all have free or near-free tiers that fit.

**1. Create a Postgres database** on the platform, or use the Supabase project
already set up. Apply the migrations in order:

```bash
psql "$DATABASE_URL" -f backend/migrations/0001_init.sql
psql "$DATABASE_URL" -f backend/migrations/0002_standalone_auth.sql
psql "$DATABASE_URL" -f backend/migrations/0003_epoch_times.sql
```

**2. Check them** before going further:

```bash
GC_DSN="$DATABASE_URL" python3 backend/tests/test_postgres_rls.py
```

Fifteen checks, non-zero exit if any fails.

**3. Create the first admin.** There is deliberately no way to do this through
the app:

```bash
GREENCORD_DATABASE_URL="$DATABASE_URL" python3 tools/provision-counselor.py \
    --db unused --name "Green Cord Coordinator" --username counselor
```

It prompts for a password. Everyone else is added from inside the app by that
admin.

**4. Run the server.** The platform terminates TLS and forwards plain HTTP
internally, so:

```
Build:  pip install "psycopg[binary]"
Start:  python3 backend/server.py --no-tls --bind 0.0.0.0 --port $PORT
Env:    GREENCORD_DATABASE_URL = <the database URL>
```

`--no-tls` is only correct behind a proxy that terminates TLS. Never run it
exposed directly.

**5. Point the app at it** and rebuild:

```bash
GREENCORD_BACKEND_URL=https://your-app.onrender.com \
GREENCORD_TEAM_ID=... GREENCORD_BUNDLE_ID=... \
  python3 tools/generate_xcodeproj.py
```

### One thing that will bite

The server keeps a single database connection behind a lock, and tells Postgres
who is acting with a session-wide `set_config`. That is correct for one process
with one connection, and **wrong for a pooled or multi-process server**: a
connection carrying the previous request's identity would answer the next
request as that user — a student seeing someone else's hours.

If you move to `gunicorn` with workers, or add a connection pool, change
`Connection.set_account` in `backend/pg.py` to `SET LOCAL` inside the
transaction serving each request. The comment there says so too.

---

## What was proven, and what it uncovered

Kept because the reasoning matters more than the result, and because the next
person will have the same questions.

**Creating a Supabase project does not, by itself, deploy this app.** Supabase
gives you a database, its own authentication and its own REST API. The app
speaks none of those — it calls `POST /auth/login` and the rest of this
project's own API. Supabase is useful here as *the database*, which is exactly
how it is used above.

**Applying the schema found three things reading it had not.**

| | |
| --- | --- |
| Access rules on live Postgres | `anon` sees nothing; a student sees only their own entries; staff see all |
| Authentication | 0001 delegated identity to `auth.users`; the server owns it. 0002 reconciles them |
| Time | 0001 used `timestamptz`; the server and the iOS models exchange epoch seconds. 0003 aligns them |

**And running it found five more**, each caught by a test rather than by
inspection: SQLite's missing boolean type, a trigger still writing `now()` into
a converted column, `jsonb` arriving already decoded, a literal `%` colliding
with placeholders, and an audit log protected by rules that silently discarded
tampering where SQLite raises.

That last one is the one to remember. The rows were never at risk, but the
guarantee was weaker than the documentation claimed, and only executing it
showed that. **A schema that has been reviewed is not a schema that works.**

---

## Option A — the Python server on Postgres (what was built)

The app keeps working unchanged. `backend/pg.py` is a SQLite-shaped interface
over psycopg, so `server.py` was not rewritten at nineteen call sites; it
translates `?` to `%s`, `BEGIN IMMEDIATE` to `BEGIN`, `COLLATE NOCASE` to
`lower()`, and converts the types the two databases disagree about — uuid,
numeric, date and jsonb — into the strings and numbers the API already returns.

Done. See *Putting it on a host* above for what remains.

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

Run both suites against whatever database you intend to use, before trusting it
with anyone's record:

```bash
GC_DSN="$DATABASE_URL" python3 backend/tests/test_postgres_rls.py
GREENCORD_DATABASE_URL="$DATABASE_URL" python3 backend/tests/test_backend.py
```

Fifteen access-rule checks and 55 behaviour tests. Both exit non-zero on
failure. If they pass, the system works on that database — which is a different
and much stronger claim than the schema having been reviewed.
