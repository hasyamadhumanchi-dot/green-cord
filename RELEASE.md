# Release path

What stands between this prototype and the App Store, in order. Each step is
marked **HUMAN-BLOCKED** (no amount of code closes it) or **CODE-READY** (already
built and proven by a named gate).

**Nothing in this repository has been submitted, listed or distributed.** That is
deliberate, and step 1 is why.

---

## 1. Written authorization from Princeton ISD / PHS — **HUMAN-BLOCKED**

**This is the blocker.** Everything else is either done or routine.

The app carries the district's name, presents itself as the Green Cord program,
and stores school records about minors. The listed publisher would be a
**personal developer account**, not the district's.

That combination is the single most likely reason for rejection. App Review
Guideline 5.2.1 asks that an app using a real institution's name and branding be
submitted by that institution or with its documented permission, and an app
handling student data under a personal account invites exactly the question
reviewers are trained to ask.

The counselor has said to build a prototype and bring it back. That is
permission to build and demo — it is not authorization to publish. What is needed
before submission:

* Written permission from the district to use the name "Princeton ISD" / "Princeton
  Senior High School", the Green Cord program name, and the panther mark. **This
  is now sharper than it was:** the app carries the district's actual logo, not a
  drawn stand-in, so this is use of their registered mark rather than an allusion
  to it. Get it in writing before submitting.
* Written agreement covering student data: who is the data controller, what may
  be collected, and how long it is kept.
* A decision on **who publishes**. Realistically the choices are:
  1. **The district enrolls** in the Apple Developer Program as an organization
     and publishes it. Cleanest, slowest.
  2. **TestFlight only**, distributed to the counselor and club members under a
     personal account. Avoids public listing, avoids most review risk, and is
     enough for a club of this size. **This is the recommended next step after
     the demo.**
  3. Publishing publicly under a personal account. Not recommended.

Until one of these is settled, do not submit.

## 2. The counselor agrees to operate and fund the backend — **HUMAN-BLOCKED**

Someone has to own the server holding the records. See PROPOSAL.md for what it
costs. Two questions need answers in writing:

* Who pays for it, and from which budget?
* **Who inherits the records if that counselor leaves PHS?** A student's service
  record is an academic record spanning four years. It must not depend on one
  person's continued employment or one personal account's password.

## 3. Retention and graduation — **HUMAN-BLOCKED (default implemented)**

The app currently implements this rule, which is a **default pending district
confirmation**:

> Deleting an account irreversibly overwrites every personal identifier — name,
> last name, username — and clears the free text and supervisor contact details
> on that student's entries. The **hours themselves are retained**, unattached to
> anyone, so the program's aggregate record stays intact.

Proven by gate B11 (`backend/tests/test_backend.py`: *"deleting an account removes
every personal identifier"*), which deletes an account and asserts no identifier
remains queryable.

What the district has to decide: what happens at graduation. Deleted? Exported to
the counselor and then deleted? Retained for N years? That answer changes both
this rule and the privacy policy, and it is a records-retention question for the
district, not a product decision.

## 4. Apple Developer Program enrollment — **HUMAN-BLOCKED**

$99/year. An organization account needs a D-U-N-S number and takes days to weeks.
A personal account is immediate. See step 1 before choosing.

## 5. Signing and provisioning — **HUMAN-BLOCKED**

The project builds unsigned today (`CODE_SIGNING_ALLOWED = NO`), which is why the
simulator gates pass without a team. To run on a real device or archive for
distribution, set `DEVELOPMENT_TEAM` in `tools/generate_xcodeproj.py` and
regenerate. Bundle id is `net.princetonisd.pshs.greencord`.

## 6. Privacy manifest — **CODE-READY** (gate E1)

`GreenCordHandbook/PrivacyInfo.xcprivacy` declares every data type the app
transmits, and nothing it does not. Each declaration maps to a real field:

| Declared type | The actual fields | Why |
| --- | --- | --- |
| `...TypeName` | `displayName`, `lastName` | So the counselor knows whose hours these are |
| `...TypeUserID` | `username` | Signing in |
| `...TypeOtherUserContactInfo` | `verifierContact` | The supervisor's email or phone, required by handbook page 15 |
| `...TypePhotosorVideos` | `evidenceURL` | Optional photo of the signed form |
| `...TypeOtherDataTypes` | `serviceDate`, `hours`, `category`, `organization`, `description`, `grade` | The service record itself |

`NSPrivacyTracking` is `false` and `NSPrivacyTrackingDomains` is empty. Every
purpose is `AppFunctionality`; none is advertising or analytics.

**No undeclared field is transmitted.** The only request bodies the app sends are
the typed structs in `RemoteAPI.swift` (`RedeemBody`, `SignInBody`, `EntryBody`,
`DecisionBody`, `CodeBatchBody`, `CheckedBody`). Their fields are exactly the
table above plus `password`, which is a credential rather than collected data.

## 7. No analytics, advertising or tracking SDKs — **CODE-READY** (gate E2)

There are no third-party dependencies at all. No SPM packages, no CocoaPods, no
Carthage, no vendored frameworks. Verified by gate G5, which greps the sources
for the common analytics and advertising SDK identifiers and finds none.

## 8. In-app account deletion — **CODE-READY** (Guideline 5.1.1(v), gates B11 and E3)

Reachable in two taps: **Account → Delete my account**, behind a confirmation
dialog that says what will be removed. It calls `DELETE /me`, which performs the
anonymization in step 3.

## 9. Age rating and the Kids Category — **decided, documented here**

* **Age rating: 4+.** The app has no objectionable content, no user-to-user
  messaging, no web view, no purchases and no advertising. The only free text one
  person writes and another reads is a student's description of their service and
  the counselor's note back — a closed channel between a student and a school
  employee, not social messaging.
* **Kids Category: no, do not enter it.** It is intended for apps aimed at
  children under 13. This app's users are 14–18. Entering the Kids Category would
  impose restrictions built for a younger audience while adding nothing here, and
  it draws COPPA scrutiny that does not apply to this age range. A 4+ rating
  outside the Kids Category is the correct placement.

## 10. Privacy policy and terms URLs — **HUMAN-BLOCKED**

App Store Connect requires a reachable privacy policy URL. None exists yet
because step 1 has not been settled — the policy has to name whoever the district
agrees is the data controller, and writing it before that is settled would be
guessing.

It must state, at minimum: what is collected (the table in step 6), who can see
it (the student themselves and the one counselor — **no student can see another
student's data**, proven by gate B6), where it is stored, how long it is kept
(step 3), and how to delete an account (step 8).

## 11. Export compliance — **answer known**

*"Does your app use encryption?"* → **Yes, but exempt.** The app uses only HTTPS
via the system's own TLS, and `CryptoKit`'s SHA-256 to verify content checksums.
Both are exempt under the standard exemption for apps using platform-provided
encryption for authentication and data integrity.
`ITSAppUsesNonExemptEncryption` is already `false` in `Info.plist`, so the
question will not be asked on each submission.

## 12. Migrating the backend to Postgres — **CODE-READY, needs running**

`backend/migrations/0001_init.sql` is the production schema: the same tables, the
same workflow, expressed as Postgres row-level-security policies rather than as
checks in Python. It has **not been applied to a real database** — Postgres could
not be installed in the environment this was built in (no Homebrew, no Docker),
so gate B1 is recorded as blocked rather than passed.

Applying it is one command against a Supabase project:

```bash
psql "$DATABASE_URL" -f backend/migrations/0001_init.sql
```

Expect to spend time on this step. Translating checks that ran in application code
into RLS policies is exactly where a subtle hole gets introduced, so re-run the
equivalents of the B2–B12 tests against the real database before any student uses
it.

## 13. Backups — **CODE-READY, decision needed**

Backup and restore are scripted and the restore has been executed once; see
RUNBOOK.md. Supabase's free tier keeps 7 days of backups, which is **not
sufficient for a four-year academic record**. Either pay for longer retention or
schedule an export somewhere the district controls.

## 14. TestFlight beta — **HUMAN-BLOCKED**

Once steps 1, 2 and 4 are settled: an internal build for the counselor, then a
small external group of five to ten students across different grades. Watch for
the things a simulator cannot show — students mistyping codes, photos of forms
taken in bad light, and whether the difference between "approved" and "awaiting
review" actually lands.

## 15. Listing copy and screenshots — **not started**

Needed at submission: name, subtitle, description, keywords, support URL, and
screenshots at the required sizes. `verification/` already holds iPhone and iPad
screenshots in light and dark mode, which are a starting point rather than
finished marketing art.

---

## Summary

| # | Step | State |
| --- | --- | --- |
| 1 | District authorization for name, mark and student data | **HUMAN-BLOCKED** |
| 2 | Who operates, funds and inherits the backend | **HUMAN-BLOCKED** |
| 3 | Retention rule at graduation | **HUMAN-BLOCKED** (default implemented, gate B11) |
| 4 | Apple Developer Program enrollment | **HUMAN-BLOCKED** |
| 5 | Signing and provisioning | **HUMAN-BLOCKED** |
| 6 | Privacy manifest matching the payload | CODE-READY (E1) |
| 7 | No analytics, advertising or tracking | CODE-READY (E2, G5) |
| 8 | In-app account deletion | CODE-READY (B11, E3) |
| 9 | Age rating 4+, not Kids Category | Decided above |
| 10 | Privacy policy and terms URLs | **HUMAN-BLOCKED** |
| 11 | Export compliance | Answer known, plist set |
| 12 | Postgres + RLS migration | CODE-READY, not yet applied (B1 blocked) |
| 13 | Backup retention | CODE-READY, decision needed |
| 14 | TestFlight beta | **HUMAN-BLOCKED** |
| 15 | Listing copy and screenshots | Not started |

**Sign in with Apple** (Guideline 4.8) is **not required here.** It applies only
when an app offers a third-party or social sign-in. This app offers neither: the
only way to create an account is an invite code issued by the counselor, and the
only way back in is a username and password held by the program's own server.
Recorded here so the determination is on the record rather than re-litigated at
submission.
