# Changing the app

A practical guide to editing this project. Assumes no prior Swift.

---

## The loop

1. Open `GreenCordHandbook.xcodeproj` in Xcode
2. Edit a `.swift` file
3. Press **⌘R**

Three to twenty seconds later it is running on the simulator with your change.

**The one exception:** if you *add a new file*, run this first, then ⌘R:

```bash
python3 tools/generate_xcodeproj.py
```

The Xcode project is generated from what is on disk rather than maintained by
hand, so new files have to be picked up. Editing existing files needs nothing.

> If you have set up signing for your phone, keep passing the same settings when
> you regenerate, or you will lose them:
> ```bash
> GREENCORD_TEAM_ID=F9G2PCXMFW GREENCORD_BUNDLE_ID=com.hasya.greencord \
>   python3 tools/generate_xcodeproj.py
> ```

---

## Where everything is

### The screens

| Screen | File |
| --- | --- |
| Reading the handbook (original pages, search) | `Views/HandbookReaderView.swift` |
| Welcome, log in, redeeming an invite code | `Views/WelcomeView.swift` |
| The counselor's dashboard | `Views/CounselorHomeView.swift` |
| A student's list of logged hours | `Views/MyHoursView.swift` |
| The form for adding or editing an entry | `Views/EntryEditorView.swift` |
| Progress, totals, category breakdown, checklist | `Views/ProgressView_GreenCord.swift` |
| Counselor's queue of submitted hours | `Views/ReviewQueueView.swift` |
| Counselor's roster, filters, CSV, invite codes | `Views/RosterView.swift` |
| Signed-in account, export, delete account | `Views/AccountView.swift` |
| Tab bar, iPad sidebar, which screens exist | `Views/RootView.swift` |

### Everything else

| Thing | File |
| --- | --- |
| Colours, the panther, status badges | `Theme/Brand.swift` and `Assets.xcassets` |
| What the app knows and does (the "brain") | `AppModel.swift` |
| Shapes of the data | `Model/` |
| Talking to the server | `Backend/` |
| Search | `Search/SearchIndex.swift` |
| Deadline reminders | `Notifications/DeadlineScheduler.swift` |
| CSV export | `Export/CSVExport.swift` |

---

## Recipes

### Change wording

Most user-facing text sits in the view files as `Text("...")` or as an
`accessibilityLabel`. Use **⇧⌘F** in Xcode to search the whole project for the
words you can see on screen.

Changing a tab name, for instance — `Views/RootView.swift`:

```swift
case .myHours: return "My Hours"      // change the right-hand side
```

The tab and the screen title both read from here, so they stay in step.

### Change a colour

Open `Assets.xcassets` in Xcode, pick a colour set (`BrandMaroon`,
`CordGreen`, `PageBackground`…), and edit the swatch. Each has an **Any
Appearance** value and a **Dark** value.

Nothing else needs touching: views refer to `Brand.maroon` rather than to a
colour literal, which is why re-skinning is a one-file job.

After changing brand colours, re-check contrast:

```bash
python3 tools/check_contrast.py
```

It reads the values out of the asset catalogue and fails if any text pair drops
below WCAG AA. It also rewrites `verification/contrast.md`.

### Replace the panther

The app carries the official Princeton ISD logo. To swap in a better copy:

1. `Assets.xcassets/PantherLogo.imageset/panther-logo.png` — the in-app mark
2. `Assets.xcassets/AppIcon.appiconset/AppIcon.png` — the icon, at 1024×1024

Both are shown through `BrandLogo` in `Theme/Brand.swift`. If the new file has a
transparent background, drop the `clipShape` there so it is not drawn as a tile.
`PantherShape` is the older drawn silhouette, kept as a fallback. See
*The panther mark* in `README.md`.

### Change the handbook

**Do not edit the text in the app.** It is extracted from the PDF, so any edit
would be overwritten the next time the pipeline runs.

Replace `content/source/PISDGreenCordHandbook.pdf`, then:

```bash
tools/publish-content.sh
```

That re-extracts, checks the result against the PDF, and rebuilds the bundled
content. Sections, search, page numbers and the per-grade requirements all
follow.

If the handbook's *rules* changed — thresholds, deadlines, category caps — also
update `content/requirements.json`. Every value there cites the page it came
from, and `tools/verify_content.py` fails if a quote no longer appears on its
cited page. That check is what stops the app drifting away from the handbook.

### Add a new screen

1. Create `Views/MyNewScreen.swift`
2. Add a case to `AppDestination` in `Views/RootView.swift` — give it a title
   and an SF Symbol name
3. Add it to `destinations(for:)` for the roles that should see it
4. Add it to both `switch` statements that build views
5. `python3 tools/generate_xcodeproj.py`, then ⌘R

Step 3 is the one that matters: it decides whether students see it, the
counselor sees it, or both. Students must never gain a route to another
student's data.

### Add a field to an hour entry

This one touches several places, in this order:

1. `backend/db.py` — add the column
2. `backend/server.py` — accept and return it (`ENTRY_FIELDS`, `entry_json`)
3. `backend/migrations/0001_init.sql` — the production schema
4. `Model/HourEntry.swift` — the app's version
5. `Backend/GreenCordAPI.swift` — `EntryDraft`
6. `Backend/LocalStore.swift` — the offline copy
7. `Views/EntryEditorView.swift` — the form field

Delete `build/greencord-*.db` and re-seed afterwards; the prototype has no
migration path for its SQLite copy.

---

## Before and after: check yourself

```bash
# 51 iOS tests
xcodebuild test -project GreenCordHandbook.xcodeproj -scheme GreenCordHandbook \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# 38 backend tests
python3 backend/tests/test_backend.py

# content still matches the PDF
python3 tools/verify_content.py

# no placeholders, no secrets, no tracking
python3 tools/check_quality.py
```

The iOS tests are not decoration. While this was being built they caught:

* a search result that did nothing when tapped on iPhone
* the reading-mode toggle vanishing after opening a section
* reminders scheduling into the past
* an infinite recursion in the notification wrapper

Run them after anything that is not just wording.

---

## Two rules worth keeping

**The handbook is the source of truth.** Every threshold, deadline and cap in
the app comes from the PDF and cites its page. If you want to change a number,
change the handbook, not the app. Where the handbook says nothing, the app says
"not specified" rather than inventing a value — keep it that way.

**Students see only their own record.** This is enforced on the server, not
just hidden in the UI. If you add a screen or an endpoint, ask whether a student
could reach another student's data through it. `backend/tests/test_backend.py`
has tests for this; add to them rather than around them.

---

## When something breaks

**Xcode shows red errors** — read the first one only. Later errors are usually
knock-on effects, and fixing the first often clears the rest.

**It built but behaves oddly** — run the tests. A failing test name usually
points straight at the cause.

**You want to undo everything** — the project is in git:

```bash
git diff                 # what you changed
git checkout -- <file>   # throw away changes to one file
```

**You have broken something badly** — tell me what you were trying to do and
paste the error. Knowing the goal matters more than the error text.
