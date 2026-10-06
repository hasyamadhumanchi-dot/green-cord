# Green Cord — Princeton Senior High School

A prototype iOS app (iPhone and iPad) for the Princeton ISD Green Cord community
service program. It presents the program handbook in two switchable reading
modes, lets students in grades 9–12 log service hours, routes every entry to the
program counselor for approval, and gives that counselor a roster of the whole
cohort.

**This is a prototype, built to show the counselor and ask for formal approval.**
It is not published, not listed on the App Store, and not distributed beyond a
simulator walkthrough. See [RELEASE.md](RELEASE.md) for what stands between here
and a release, and [PROPOSAL.md](PROPOSAL.md) for the one-page summary written
for the counselor.

---

## What it does

**Signing in** — the app opens on Log In / Create Account and nothing is
reachable before that, the handbook included. An account exists only by
redeeming an invite code the counselor issued to that named student, so signing
up is a confirmation rather than a registration.

**Reading the handbook** — a list of sections that opens the original PDF page
via PDFKit. The pages are the handbook; nothing is retyped. The text is still
extracted behind the scenes, but only to drive search and to give VoiceOver
something to read. Search returns the section *and* the page.

**Logging hours** — a student records a date, hours, category, organization,
description and the supervisor who can verify it, optionally with a photo of the
signed form. Entries can be edited while they are a draft, or after a counselor
declines them or asks for changes. Once approved they are permanent.

**Progress** — approved hours against that student's own grade threshold (25 /
50 / 75 / 100, from handbook page 6), broken down by category against the
handbook's caps, with the grade's deadline. Hours awaiting review are shown as a
separate, visibly different figure and are never added to the approved total.

**For the counselor** — a queue of submitted entries to approve, decline or send
back with a note; a sortable roster of every student filterable by grade and
last-name range; CSV export; invite-code generation and revocation; and the
ability to enter hours on a student's behalf from a paper form.

**Offline** — the handbook, the requirements and the student's own entries are
all readable with no network. New entries queue on the device and sync once,
without duplication, when the connection returns.

**Updatable** — the app ships a copy of the handbook and checks a manifest on the
school website for a newer one. An update is applied only when it is genuinely
newer and every file matches its published SHA-256.

---

## Requirements

* macOS with Xcode 26 or later (built and verified against Xcode 27.0)
* Python 3.9+ for the content pipeline and the prototype backend — both use only
  the standard library, so there is nothing to install
* No third-party Swift packages. No analytics, advertising or tracking SDKs.

---

## Open, build and run

```bash
open GreenCordHandbook.xcodeproj
```

Pick the **GreenCordHandbook** scheme and run. From the command line:

```bash
# iPhone
xcodebuild -project GreenCordHandbook.xcodeproj -scheme GreenCordHandbook \
  -destination 'platform=iOS Simulator,name=iPhone 17' clean build

# iPad
xcodebuild -project GreenCordHandbook.xcodeproj -scheme GreenCordHandbook \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' clean build

# Tests
xcodebuild test -project GreenCordHandbook.xcodeproj -scheme GreenCordHandbook \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

### Simulators used for verification

The gates for this build named **iPhone 16** and **iPad Pro 13-inch (M4)**.
Neither exists in this environment — Xcode 27.0 ships only the iOS 27.0 runtime,
whose devices are the iPhone 17/18 and the M5 iPads. The substitutes used, and
recorded everywhere a result is reported, are:

| Asked for | Used | Why |
| --- | --- | --- |
| iPhone 16 | **iPhone 17** | The iOS 27.0 runtime has no iPhone 16 |
| iPad Pro 13-inch (M4) | **iPad Pro 13-inch (M5)** | Same |

`xcrun simctl list devices available` shows what this machine actually has.

### The Xcode project is generated

`GreenCordHandbook.xcodeproj` is produced by `tools/generate_xcodeproj.py` rather
than edited by hand. **Adding a Swift file means dropping it in the right
directory and re-running that script** — the generator walks the tree, so new
files are picked up automatically and object ids stay stable:

```bash
python3 tools/generate_xcodeproj.py
```

Editing the project in Xcode's UI works, but the next regeneration will discard
those edits. Change the generator instead.

---

## Layout

```
content/                   the handbook, extracted and structured
  source/                  the source PDF, byte-identical to the school site's
  handbook-outline.md      every heading with its page range
  handbook.json            extracted section text (search + VoiceOver only)
  requirements.json        thresholds, categories, deadlines - each citing a page
  manifest.json            the versioned update payload
  manifest.schema.json     what a manifest must look like
  source-of-truth.md       where every value came from, with URLs

backend/                   the prototype server
  server.py                HTTPS, session tokens, every authorization rule
  db.py                    SQLite storage mirroring the Postgres schema
  migrations/0001_init.sql the production Postgres + row-level-security schema
  tests/test_backend.py    38 tests, run over a real socket

GreenCordHandbook/         the app
GreenCordHandbookTests/    unit tests (Swift Testing)
GreenCordHandbookUITests/  UI tests (XCTest)
tools/                     the content pipeline, project generator and checks
verification/              screenshots, contrast and accessibility reports
```

---

## The content pipeline

The handbook is not typed into the app by hand. It is extracted from the PDF:

```bash
# Extract, rebuild handbook.json and handbook-outline.md, and verify both
# against the source PDF
swiftc -O tools/extract_pdf.swift -o .build/extract_pdf
.build/extract_pdf content/source/PISDGreenCordHandbook.pdf > .build/raw.json
python3 tools/build_content.py .build/raw.json
python3 tools/verify_content.py
```

`verify_content.py` is the interesting one. It checks that the section count in
the outline equals the headings found in the raw extraction, that every section
maps to a real page, that every value in `requirements.json` cites a page and
that the quoted text really appears on it — and it cross-checks the whole outline
against the PDF's own table of contents, which was written by the handbook's
authors rather than by this pipeline.

That cross-check found one thing worth knowing: **the handbook's table of
contents lists SERVICE HOUR REQUIREMENTS on page 5, but the heading is on page
6.** That is an error in the source document. The app navigates to the page the
heading is really on, and the verifier reports the discrepancy rather than hiding
it.

### Publishing a content update

When the counselor revises the handbook:

1. Export the Google Doc to PDF over `content/source/PISDGreenCordHandbook.pdf`.
2. Bump `contentVersion` in `content/handbook.json` and
   `content/requirements.json` to today's date as `YYYY.MM.DD`.
3. Run `tools/publish-content.sh`.

It rebuilds the content, verifies it, stages `build/publish/`, writes a manifest
with fresh checksums, validates the result against the JSON Schema, and prints
the exact files to upload and where each one goes.

Installed copies of the app pick the update up on next launch. **No App Store
submission is involved** — this delivers data, never code.

### Where the manifest URL is configured

One constant, in `GreenCordHandbook/Content/ContentStore.swift`:

```swift
enum ContentSource {
    static let manifestURL = URL(
        string: "https://pshs.princetonisd.net/greencord-app-content/manifest.json"
    )!
}
```

**That URL is a placeholder.** Nobody has yet confirmed a writable path on the
school site. Until one exists the app simply never finds an update and keeps
using the copy it shipped with, which is a correct and quiet failure.

The manifest must look like `content/manifest.schema.json` describes:

```json
{
  "schemaVersion": 1,
  "contentVersion": "2026.08.21",
  "publishedAt": "2026-09-20T00:00:00Z",
  "files": [
    {"role": "handbook",     "name": "handbook.json",
     "url": "https://.../handbook.json",     "sha256": "…", "bytes": 70245},
    {"role": "requirements", "name": "requirements.json",
     "url": "https://.../requirements.json", "sha256": "…", "bytes": 10700},
    {"role": "pdf",          "name": "PISDGreenCordHandbook.pdf",
     "url": "https://.../PISDGreenCordHandbook.pdf", "sha256": "…", "bytes": 497010}
  ]
}
```

HTTPS only — the app refuses `http://` before it makes the request.

---

## The backend

The production target is **Postgres with row-level security**, hosted on
Supabase. That schema is `backend/migrations/0001_init.sql` and is the
authoritative statement of who may read and write what.

Postgres could not be installed in the environment this prototype was built in
(no Homebrew, no Docker), so the prototype runs a **standard-library Python
server backed by SQLite** that enforces the same rules, over HTTPS, so the app
and its tests exercise a real server over a real socket. See
[RUNBOOK.md](RUNBOOK.md) to run it, and RELEASE.md for the migration path.

```bash
tools/gen-certs.sh                     # self-signed cert for local HTTPS
tools/seed-demo.sh --keep-running      # fresh database, counselor, demo cohort
python3 backend/tests/test_backend.py  # 38 tests over a real socket
```

To point the app at it, set `GreenCordBackendURL` in
`GreenCordHandbook/Info.plist` (or the `GREENCORD_BACKEND_URL` environment
variable in the scheme). **With no address configured the app runs as a reader**:
the handbook, search, requirements and the whole reading experience work, and the
screens that need an account say so. That is how the simulator demo runs.

---

## Branding

| Token | Value | Where it came from |
| --- | --- | --- |
| `BrandMaroon` | `#5A1115` | `--primary-color` in the program page's stylesheet |
| `BrandSilver` | `#BEBFC1` | `--secondary-color`, same source |
| `CordGreen` | `#1B6B3A` | Chosen for the cord itself; not a district colour |

Defined once each in `GreenCordHandbook/Assets.xcassets`, with a lighter variant
for dark mode. Views refer to `Brand.maroon` and never to a colour literal.
Measured contrast ratios are in [verification/contrast.md](verification/contrast.md).

### The panther mark

The app carries the **official Princeton ISD panther**, supplied by the user and
kept in `content/source/brand/`. It appears in two places, both through
`BrandLogo` in `GreenCordHandbook/Theme/Brand.swift`: the welcome screen and the
navigation header. It is also the app icon.

**It is not ideal artwork and should be replaced before submission.** The file
supplied is a 554×554 JPEG with its own maroon background and no transparency,
so the app icon is an upscale and the mark has to be drawn as a rounded tile
rather than floated on the page. Ask the district communications office for a
vector (PDF/SVG) or a 1024px PNG with a transparent background.

To swap it in:

1. Replace `GreenCordHandbook/Assets.xcassets/PantherLogo.imageset/panther-logo.png`.
2. Replace `GreenCordHandbook/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
   at 1024×1024.
3. If the new file has transparency, drop the `clipShape` in `BrandLogo` so it is
   not tiled.

`PantherShape` is the original drawn silhouette, kept as a fallback for anywhere
the real logo is too detailed to read.

The brand maroon `#5E0227` was sampled from that logo file. Changing the logo
means re-running `tools/check_contrast.py`, which reads the asset catalogue and
rewrites `verification/contrast.md`.

---

## Running the demo

```bash
tools/demo-start.sh
```

Backend with fresh data, both simulators prepared, logins and invite codes
printed. Leave the window open; closing it stops the backend. The script is
`DEMO.md`, and `DemoRehearsalTests` is the pre-flight check that every screen
renders cleanly against a live server.

---

## Verification

```bash
python3 tools/verify_content.py        # content against the source PDF
python3 tools/validate_manifest.py     # manifest schema + checksums
python3 tools/check_contrast.py        # WCAG AA, writes verification/contrast.md
python3 tools/check_accessibility.py   # writes verification/accessibility.md
python3 backend/tests/test_backend.py  # backend suite
tools/capture-screenshots.sh           # launch both device families, screenshot
```

`verification/` holds the screenshots for both device families in light and dark
mode, the contrast report and the accessibility report.

---

## What this prototype deliberately does not do

* It is **not on the App Store** and must not be submitted until Princeton ISD
  has authorized the use of the district name and student data in writing. See
  RELEASE.md.
* It holds **no real student data**. Every name in `tools/seed_demo.py` is
  invented.
* Evidence photos are recorded as attached but are not uploaded — that needs
  object storage on the server, which is part of the post-approval build.
