# Handover

Written for whoever has this next — most likely you, months from now, having
forgotten the details; possibly a younger student; possibly district IT.

It assumes no memory of how any of it was built.

---

## What this is, in one paragraph

An iPhone and iPad app for the Princeton HS Green Cord program. Students log
community service hours; staff review and approve them; approved hours become a
permanent record. It was built from the program's handbook, demonstrated to the
program coordinator, and changed once on her feedback to add staff roles. It has
never been deployed: it runs on a laptop.

---

## The five-minute version

```bash
cd /Users/hasya/Documents/GreenCord
tools/demo-start.sh
```

Backend with demo data, both simulators, logins and invite codes printed. Leave
the window open — closing it stops the backend. `DEMO.md` is the script to
follow.

If something looks wrong, run the pre-flight:

```bash
TEST_RUNNER_GREENCORD_BACKEND_URL=https://127.0.0.1:8443 \
  xcodebuild test -project GreenCordHandbook.xcodeproj -scheme GreenCordHandbook \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:GreenCordHandbookUITests/DemoRehearsalTests
```

It signs in as both roles, walks every screen, and fails on a crash, an error
banner, a false "offline" notice, developer text on screen, an empty dashboard
or an empty review queue.

---

## Which document answers what

| Question | File |
| --- | --- |
| What is this and what does it do | `README.md` |
| How do I show it to someone | `DEMO.md` |
| How do I change the app | `CHANGING.md` |
| How do I run the backend, add staff, reset a password | `RUNBOOK.md` |
| What would deploying actually take | `DEPLOY.md` |
| What stands between this and an App Store release | `RELEASE.md` |
| What has been verified, and how | `GATES.md` |
| The one-page summary for the counselor | `PROPOSAL.md` |
| Putting it on a physical iPhone | `PHONE.md` |

---

## Things that will break, and what to do

**"Signing in fails."** The backend is not running. `tools/demo-start.sh`.
Check with `curl -sk https://127.0.0.1:8443/health`.

**"The app on my phone stopped opening."** A free Apple ID signs apps for seven
days. Rebuild and reinstall — `PHONE.md`. If you have paid the $99 and used
TestFlight, builds expire after **90 days** instead, and you upload a new one.

**"The app on my phone can't sign in, but the simulator can."** The phone build
points at a specific address. If your Mac's IP changed — different wifi, router
restart — it is wrong. Find the new one with `ipconfig getifaddr en0`, then
rebuild with `GREENCORD_BACKEND_URL=https://<that-ip>:8443`.

**"I added a Swift file and Xcode doesn't see it."** The project file is
generated. Run `python3 tools/generate_xcodeproj.py`. If you have set up phone
signing, pass the same settings back or you will lose them:
`GREENCORD_TEAM_ID=... GREENCORD_BUNDLE_ID=... python3 tools/generate_xcodeproj.py`.
This is a real trap — it has already cost one person an afternoon.

**"The counselor is locked out."** If another admin exists, they can issue a
reset in the app. If not, see *Resetting a password* in `RUNBOOK.md` — it is a
one-line command.

**"The demo data is wrong or the roster is empty."** Re-run
`tools/demo-start.sh`. It wipes and reseeds. Invite codes change every time, so
use the ones it prints.

---

## Handing it to someone else

Three things transfer separately. In this order:

1. **The repository.** GitHub → Settings → Transfer ownership. Or they fork it.
   Costs nothing, loses nothing.
2. **The backend**, if one ever exists. Whoever owns the hosting account owns
   the student records. This is the piece that actually matters legally — see
   `RELEASE.md`.
3. **The app**, if it is ever on the App Store. Apple supports transferring an
   app between developer accounts; users update seamlessly.

**Inside the app, handover is already built.** The admin adds the new person as
an admin, then steps themselves down. The server refuses to leave the program
with no admin, so the order is enforced. `RUNBOOK.md` has the sequence.

---

## What is honestly unfinished

Not a wish list — the things someone will trip over.

- **No hosted backend.** The app talks to a server that runs on a laptop and
  stores data in SQLite. `DEPLOY.md` sets out what changing that involves,
  including an authentication mismatch between the server and the Postgres
  schema that is the real obstacle.
- **Photo evidence is a marker, not an image.** Attaching a photo records *that*
  a form was attached. The image never leaves the phone, so a reviewer cannot
  see it. Real storage needs a hosted backend first.
- **The district has not authorised anything in writing.** The app carries the
  Princeton ISD name and panther logo. Verbal encouragement from a counselor is
  not authorisation to publish — `RELEASE.md` is explicit about this.
- **The panther artwork is a 554px JPEG** with no transparency, so the app icon
  is an upscale. A vector from the district communications office is a drop-in
  replacement — `README.md` says where.
- **The content manifest URL is a placeholder.** Handbook updates will work once
  a real path on the school website exists; until then the app keeps its bundled
  copy, which is the correct behaviour.
- **One `try!` remains** in the app's launch path, for SwiftData failing to
  create even an in-memory store. Documented where it is.

---

## What is genuinely solid

So that whoever inherits this knows where *not* to spend their first week.

- **The access rules.** A student cannot read another student's hours, reach the
  roster, edit an approved entry, approve anything, or promote themselves. Each
  is asserted by a test against a running server, and the same rules were
  verified against a real Postgres database with row-level security — see the
  table in `DEPLOY.md`.
- **The approval workflow.** Transitions are enforced server-side, approved
  entries are immutable to students, and the audit log is append-only with
  UPDATE and DELETE blocked by triggers.
- **The staff model.** Roles, invites, promotion, removal, and the guarantee
  that the program always has an admin.
- **The content pipeline.** Every requirement in the app cites the handbook page
  it came from, and a test checks the app against the extraction rather than
  against itself.

118 tests across the backend and both device families. `GATES.md` records each
check with its evidence.

---

## If you are deciding whether to continue it

Fair questions, honestly answered.

**Is it worth deploying?** Only if the program will actually use it. That is a
conversation with the coordinator, not a technical question. The app is ready for
a pilot; the infrastructure is not.

**Could a student maintain it?** Yes, with Swift and Python familiarity. It has
no third-party dependencies, which is unusual and deliberate — nothing to go
stale.

**What would I do first?** Settle the authentication question in `DEPLOY.md`
before writing any code. Everything else follows from it.

**And if nobody continues it?** It remains a complete, documented, tested piece
of work that solved a real problem for a real person, and says plainly what it
does and does not do. That is not nothing.
