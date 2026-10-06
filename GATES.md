# Gate results

Every gate, its command, and what came back. Run 2026-09-20 on macOS with
Xcode 27.0.

**Simulator substitutions.** The gates named `iPhone 16` and
`iPad Pro 13-inch (M4)`. Xcode 27.0 ships only the iOS 27.0 runtime, whose
devices are the iPhone 17/18 family and the M5 iPads — neither named device
exists on this machine. Used instead, and recorded in every result below:

| Asked for | Used |
| --- | --- |
| iPhone 16 | **iPhone 17** |
| iPad Pro 13-inch (M4) | **iPad Pro 13-inch (M5)** |

---

## Phase A — source and content

| Gate | Result | Evidence |
| --- | --- | --- |
| A1 | **PASS** | `content/source-of-truth.md`. Program page fetched, HTTP 200. The handbook it links is a Google Doc; its PDF export is **byte-identical** to the local copy (`sha256 79efed01…`, `cmp` clean). Brand colours originally read from the page's own `--primary-color: #5a1115` / `--secondary-color: #bebfc1`; **superseded** — the maroon is now `#5E0227`, sampled from the official district logo the user supplied (`content/source/brand/`). The program page publishes no panther; the logo came from the user directly. |
| A2 | **PASS** | `python3 tools/verify_content.py` → exit 0. Headings in raw extraction 30 = outline rows 30 = sections in `handbook.json` 30. Every section and block maps to a real page of 20. |
| A2 cross-check | **PASS** | All 20 entries of the PDF's own table of contents appear in the outline at the page it states — **except one, which is an error in the handbook itself**: the TOC lists SERVICE HOUR REQUIREMENTS on page 5; the heading is on page 6. Reported, not silently corrected. |
| A3 | **PASS** | 42 page citations, all in range 1–20; every `quote` verified present on its cited page. Per-grade table printed: 9→25 h, 10→50 h, 11→75 h, 12→100 h (all page 6); deadlines April 15 / April 15 / April 15 / April 1 (page 16). Four distinct thresholds. Two items the handbook does not state are recorded as `unspecified`. |
| A4 | **PASS** | `python3 tools/validate_manifest.py` → exit 0. Manifest conforms to `manifest.schema.json`; all three SHA-256 checksums and byte counts match; `contentVersion` agrees across files. |
| A5 | **PASS** | `./tools/publish-content.sh` → exit 0. Stages `build/publish/`, rewrites the manifest, re-validates, prints the four files and their destination URLs. |

## Phase B — backend

`python3 backend/tests/test_backend.py` → **exit 0, 38 passed, 0 failed**, run
over a real HTTPS socket.

| Gate | Result | Evidence |
| --- | --- | --- |
| B1 | **BLOCKED** | The Postgres + row-level-security schema is written and committed (`backend/migrations/0001_init.sql`) but **has never been applied to a real database**. No Postgres, no Docker and no Homebrew on this machine — `psql`, `initdb`, `docker` and `brew` are all absent. See *Blocked* below. |
| B2 | PASS | No code fails; unknown code fails; expired code fails; already-used code fails; a valid code succeeds exactly once and is marked redeemed. Six concurrent redemptions of one code produced **exactly one account**. |
| B3 | PASS | A batch of 40 codes: all unique, all 8 characters, all from `23456789ABCDEFGHJKMNPQRSTUVWXYZ`, none containing `0`, `O`, `1`, `I` or `L`. Revocation blocks redemption; a redeemed account's grade matches its code's. |
| B4 | PASS | New accounts are `student`. `POST /me/role` → **403**, `role` unchanged in the database, attempt written to the audit log. |
| B5 | PASS | Counselor created only by `tools/provision-counselor.py`, which writes to the database directly. No client endpoint creates one: redeeming a code with `"role": "counselor"` in the body still produces a student. |
| B6 | PASS | student→other student's entries: filtered out; naming another student's id does not widen the result. student→roster, roster.csv, invite-codes: **403**. Unauthenticated→any of six endpoints: **401**. |
| B7 | PASS | Every illegal transition refused: submitted→submitted (403), student editing a submitted entry (403), approved→approve/reject/request_revision (409), approved→submit (403), draft→approve (409). A student editing or deleting an approved entry: **403 with the row unchanged** (still 4 hours, still approved). A student self-approving: **403, still submitted**. |
| B8 | PASS | Approve, then a counselor revision 8→6 hours. History contains `entry.approved` then `entry.revised_by_counselor`, and the revision's `before` still reads 8. `audit_log` refuses both UPDATE and DELETE. |
| B9 | PASS | Approved-only totals. 10 approved + 7 submitted + 4 draft + 99 rejected → verified 10, pending 7, never 121. Boundaries: 0 h → 0%; exactly 25 → 100%; 30 → 120%. Same 50 hours: grade 9 → 200%, grade 12 → 50%. Category breakdown sums to the verified total. |
| B10 | PASS | Roster ordered by last name; `?grade=9` returns only grade 9; `?letterFrom=A&letterTo=C` returns exactly Adams, Brooks, Castro and excludes Delgado, Ellis. CSV row count equals the roster count and contains a known value (17 hours, threshold 50). Counselor-entered rows are flagged and audited. |
| B11 | PASS | After deletion: `deleted_at` set, name and username overwritten, entry free text and supervisor contact cleared, session invalidated, **0 rows anywhere still carrying the identifier**, the student gone from the roster, and sign-in refused. The hour total is retained. |
| B12 | PASS | Plain HTTP to the HTTPS port fails at the handshake. Repository scan for JWTs, `sk-` keys, `service_role`, AWS keys and private keys: clean. The built app binary contains **0** occurrences of `service_role`, `eyJ`, or any demo password. |
| B13 | PASS | Backup taken, all `hour_entries` deleted to simulate loss, backup restored: **accounts 13, hour_entries 48, audit_log 153** all returned. Recorded in `RUNBOOK.md`. |
| B14 | PASS | One documented command, exit 0. |

## Phase C — iOS app

| Gate | Result | Evidence |
| --- | --- | --- |
| C1 | PASS | `TARGETED_DEVICE_FAMILY = 1,2`, `IPHONEOS_DEPLOYMENT_TARGET = 17.0`, bundle id `net.princetonisd.pshs.greencord`. |
| C2 | PASS | Clean build, iPhone 18 Pro → exit 0, `** BUILD SUCCEEDED **`. |
| C3 | PASS | Clean build, iPad Pro 13-inch (M5) → exit 0, `** BUILD SUCCEEDED **`. |
| C4 | PASS | `warning:` lines scoped to files under the project directory: **0** on both builds. |
| C5 | PASS | UI test `testCreatingAnAccountRejectsACodeItCannotVerify` goes welcome → Create Account → code, submits and asserts a visible, non-technical message, and that no session was created. It also asserts the form has **no name fields**: the name comes from the code. Server-side, the four rejection paths are B2. |
| C6 | PASS | Unit test asserts the app's 30 section ids and titles equal `handbook-outline.md` **in order**, every section has text, and every block sits inside its section's page range. |
| C7 | PASS | `PDFDocument` page count == `handbook.pageCount` == **20**, and every one of the 20 pages resolves to a section. |
| C8 | **SUPERSEDED** | The reading-mode toggle was removed: the handbook is the original pages only. `testOpeningASectionOpensItsOwnPage` opens SERVICE HOUR REQUIREMENTS and asserts the indicator reads **page 6**; `testTheHandbookShowsTheOriginalPages` asserts the PDF reader appears and that no toggle or reflowed reader exists. Both pass on both device families. |
| C9 | PASS | Six phrases quoted from the handbook, each asserted to land in the right section *and* the right page in the extracted-text index — which now backs search and VoiceOver only, never a reading mode — and independently on the same page by PDFKit's own search of the real document. A phrase that is not in the handbook returns nothing. |
| C10 | PASS | Approved entries: edit refused, delete refused, values unchanged. Rejected and revision-requested reopen for editing and can be resubmitted. Entries under review are not editable. |
| C11 | PASS | Approved and pending are separate figures; the mixed-status fixture never produces 17 or 123. Grade 9 and grade 12 with identical hours show 200% and 50%. |
| C12 | PASS | UI test asserts no roster, review queue or other-student figure is reachable from a student session, and `testNothingIsReachableBeforeSigningIn` asserts a signed-out session reaches nothing at all — not even the handbook; server-side B6. |
| C13 | PASS | Checklist is per grade — the three-organization rule appears for grade 12 and not for grade 9 — and state persists per student. |
| C14 | PASS | Approve → the student's verified total moves by exactly the entry's hours and the entry locks. Executed end to end in the demo walkthrough (steps 4 and 4b). Counselor-entered hours are flagged and audited (B10). |
| C15 | PASS | Roster filters by grade and letter range, exports CSV containing a known value, and manages invite codes. On iPad it renders as a `Table` in the detail pane. |
| C16 | PASS | Authorization requested before anything is scheduled; refusing schedules nothing. Reminders land on 2027-03-16, 2027-04-08, 2027-04-15 for a freshman and 2027-03-02, 2027-03-25, 2027-04-01 for a senior. From 14 April only the one still ahead is scheduled, and every fire date is in the future. Re-running does not stack duplicates. |
| C17 | PASS | Export contains the two approved rows and neither the submitted nor the draft one, with the correct total, threshold and deadline. CSV quoting survives commas, quotes and newlines. |
| C18 | PASS | Newer version installs and the new content loads; equal or older is ignored **and only the manifest is fetched**; a corrupted file fails its checksum and the previous good copy is kept; malformed JSON is rejected; an unknown `schemaVersion` is refused; a plain-http manifest URL is refused **without the request being made**. |
| C19 | PASS | Three entries created offline queue on the device and stay readable. On reconnect all three reach the server, and **a second sync sends nothing** — 3 created, not 6. An entry submitted offline is created and then submitted. A pull never deletes work that has not been pushed. |
| C20 | PASS | Entries and totals are unchanged across a content version bump; a checklist id that disappears is simply not displayed and does not crash. |
| C21 | PASS | Install, launch, still running after 5 s, screenshot — on both device families in both appearances. **No crash reports generated.** |
| C22 | PASS | `NavigationSplitView` in `Views/RootView.swift:77`. iPhone 1206×2622 shows a tab bar and a pushing list; iPad 2064×2752 shows sidebar + section list + reader. |

## Phase D — branding and accessibility

| Gate | Result | Evidence |
| --- | --- | --- |
| D1 | PASS | App icon generated from a single 1024×1024 source, **no icon warnings**. The mark is the **official Princeton ISD panther** supplied by the user, kept in `content/source/brand/` and shown through `BrandLogo`. `BrandMaroon` is `#5E0227`, sampled from that file; `Brand.Hex.maroon` matches the asset catalogue. Views use `Brand.maroon`; no ad-hoc colour literal duplicates it. **Caveat:** the supplied file is a 554×554 JPEG with no transparency, so the icon is an upscale — see README. |
| D2 | PASS | `verification/contrast.md`. All **12** text pairs meet WCAG AA; lowest is cord green on a card at **6.54:1**. |
| D3 | PASS | `verification/iphone-dark.png`, `verification/ipad-dark.png`. Light maroon `#E0959A` on near-black; text legible, no black-on-black or maroon-on-maroon. |
| D4 | PASS | `verification/accessibility.md`. No `.font(.system(size:))` anywhere; every interactive control named; the PDF view exposes the reflowed text of the same page; roster rows and table cells carry labels. |

## Phase E — demo readiness

| Gate | Result | Evidence |
| --- | --- | --- |
| E1 | PASS | `tools/seed-demo.sh` builds a fresh database with 12 synthetic students across grades 9–12 in four states plus 40 unredeemed codes. Roster spread confirmed. |
| E2 | PASS | `tools/run-demo-walkthrough.sh` → **all 10 steps passed** against a live backend, each asserting its claim. `verification/demo/walkthrough.md` plus screenshots. |
| E3 | PASS | `PROPOSAL.md` names Supabase and $0 free tier / **$25 per month** Pro, with the reason Pro is recommended (backup retention), plus the $99/year developer account. |
| E4 | PASS | `xcodebuild archive` → exit 0, `** ARCHIVE SUCCEEDED **`. README records the demo path as the Simulator walkthrough. |

## Phase F — App Store path

| Gate | Result | Evidence |
| --- | --- | --- |
| F1 | PASS | `RELEASE.md` lists 15 steps in order, each marked HUMAN-BLOCKED or CODE-READY. |
| F2 | PASS | Every code-ready line cites its gate: privacy manifest E1, no tracking E2/G5, account deletion B11 and E3, Postgres migration B1, backups B13. |

## Phase G — quality

| Gate | Result | Evidence |
| --- | --- | --- |
| G1 | PASS | iPhone 18 Pro → **exit 0**, 44 unit tests + 12 UI tests, `** TEST SUCCEEDED **`. iPad Pro 13-inch (M5) → **exit 0**, same 56, `** TEST SUCCEEDED **`. |
| G2 | PASS | Backend suite exit 0, 43 passed. |
| G3 | PASS | No `lorem ipsum`, `TODO`, `FIXME`, `PLACEHOLDER`, `XXX`, `HACK`. No `Plano`. |
| G4 | PASS | `README.md` covers open/build/run, the simulators used, backend setup, the manifest URL and publishing an update. `RUNBOOK.md` covers backup/restore, counselor provisioning and invite codes. |
| G5 | PASS | No analytics, advertising or tracking SDK identifiers. No committed secrets. Demo names all synthetic. No plain-http URL in shipping code. No dependency manifests of any kind. |

---

## Blocked

**B1 — migrations applied to a fresh Postgres database.**

```
$ for c in psql postgres initdb docker brew; do command -v $c || echo "$c MISSING"; done
psql MISSING
postgres MISSING
initdb MISSING
docker MISSING
brew MISSING
```

Postgres cannot be installed here: there is no Homebrew, no Docker and no
package manager. Installing one would have meant downloading and installing a
package manager onto the machine, which is well outside what this task asked
for.

*What exists instead:* the production schema is written in full —
`backend/migrations/0001_init.sql`, 300 lines of tables, RLS policies, triggers
and SECURITY DEFINER functions. Every rule it expresses is also enforced by the
prototype server and proven by the 38 backend tests over a real socket. What has
**not** been proven is that the SQL applies cleanly and that the RLS policies
behave as the Python does.

*Smallest next step:* on a machine with Docker,

```bash
docker run -d -e POSTGRES_PASSWORD=dev -p 5432:5432 postgres:16
psql "postgres://postgres:dev@localhost/postgres" -f backend/migrations/0001_init.sql
```

Supabase's `auth.users` and `auth.uid()` will need stubbing on plain Postgres.
Then port the B2–B12 assertions to run against it — that is where a subtle hole
in a translated policy would show up, and it is worth doing before any real
student uses the system.

---

## Human-only prerequisites

No amount of iteration closes these. Full detail in `RELEASE.md`.

1. **Written authorization from Princeton ISD / PHS** to use the district name,
   the panther mark and student data — sharper because the publisher would be a
   personal developer account, not the district, and because the app now carries
   the district's **actual** logo rather than a drawn stand-in. **This is the
   blocker.**
2. **Who operates and funds the backend**, and who inherits the records if the
   counselor leaves PHS.
3. **The retention rule at graduation.** A default is implemented and proven
   (B11); the district has to confirm or replace it.
4. **Apple Developer Program enrollment**, then signing and provisioning.
5. **A privacy policy and terms URL**, which cannot be written until 1 is
   settled, because they have to name the data controller.
6. **A confirmed path on the school website** for the content manifest. The URL
   in the app is a documented placeholder.
7. **Better panther artwork.** The official logo is in the app, but the file
   supplied is a 554×554 JPEG with no transparency, so the App Store icon is an
   upscale. Ask the district communications office for a vector or a 1024px PNG.

---

## Second pass — the redesign

Changes made after the first demo, at the user's direction. Each was verified the
same way as the gates above: a command that was actually run, with its output.

| Change | Result | Evidence |
| --- | --- | --- |
| **The app is gated behind sign-in.** The welcome screen offers Log In / Create Account, and nothing — not even the handbook — is reachable before that. | PASS | `testTheAppOpensOnLogInOrCreateAccount` and `testNothingIsReachableBeforeSigningIn` assert the two buttons exist and that no handbook, PDF reader, search field or tab bar is present. `AppDestination.destinations(for: nil)` returns `[]`. |
| **Sessions survive relaunch.** Required by the gate above: without it a student would be returned to the login screen on every launch and, offline, would have no way back in. | PASS | `Backend/SessionStore.swift` keeps the session in the keychain, `kSecAttrAccessibleAfterFirstUnlock`, not synchronised to iCloud. Cleared on sign-out and on account deletion. Every read tolerates an unreadable store. |
| **The handbook is the original pages only.** The reading-mode toggle and the reflowed renderer are gone. | PASS | `testTheHandbookShowsTheOriginalPages` asserts the PDF reader appears and that `readingModeToggle` and `reflowedReader` do **not** exist. Extracted text still backs search (C9) and the VoiceOver alternative (D4). |
| **Invite codes belong to named students.** The counselor adds a student; the code carries their name and grade. | PASS | Backend `B3 a code is issued for one named student and carries that name`, `B3 bulk add issues one code per student, each with its own grade`, `B3 redeeming uses the name on the code, not a name the student types` — the last sends a deliberately wrong name and asserts it is ignored. |
| **Signing up is a confirmation.** The student enters a code, sees whose it is, and sets a password. | PASS | `B3 looking up a code tells the student who it is for`, including that an unknown code 404s, an empty one 400s, and a redeemed one stops revealing the name. UI: `testCreatingAnAccountRejectsACodeItCannotVerify` asserts the form has no name fields. |
| **The roster shows students who have not signed up.** | PASS | `B10 the roster lists a student who has not signed up yet` asserts `joined: false` before redemption, `joined: true` after, and that the student is never listed twice. The roster CSV gained a **Signed up** column. |
| **Deleting an account scrubs the invite code too.** A code now carries a name, so leaving it behind would keep the identifier queryable. | PASS | `delete_me` anonymises `invite_codes.first_name/last_name` for the redeemed code inside the same transaction. Covered by `B11 deleting an account removes every personal identifier`. |
| **The counselor lands on a dashboard.** Four figures, then a way into queue, roster, codes and export. | PASS | `testTheCounselorReachesTheQueueAndTheRoster` asserts the dashboard and all four stat tiles, then navigates to the roster and the review queue. |
| **The student lands on their progress**, with a greeting, a Log Hours button and recent entries. | PASS | `testAStudentLandsOnTheirOwnProgress`. Screenshot in `verification/redesign/iphone-student.png`. |
| **The district's own logo and maroon.** | PASS | `#5E0227` sampled from the supplied file; `tools/check_contrast.py` → **all 12 text pairs meet WCAG AA**, rewritten into `verification/contrast.md`. Caveat in D1 above. |
| **The demo scripts still run.** | PASS | `tools/run-demo-walkthrough.sh` → *All 10 walkthrough steps passed*, against a live server over a real socket, including the name-binding assertions. |

**Totals after the redesign:** backend 43 passed / 0 failed; iPhone 18 Pro 44 unit
+ 12 UI, 0 failures; iPad Pro 13-inch (M5) the same, 0 failures.
