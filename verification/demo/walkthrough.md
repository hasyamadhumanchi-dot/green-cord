# Demo walkthrough

`tools/run-demo-walkthrough.sh` executed the DEMO.md script end to end
against a live backend. Every step below asserts what it claims: if the
approval had not moved the total, or the entry had not locked, this run
would have failed.

Backend: `https://127.0.0.1:8455`

### Step 1 - Redeem an invite code issued to a named student

* code UN5KSZS6 was issued to Mike Mapleton, grade 11
* account created as role=student, grade=11
* name came from the code, not the form: Mike Mapleton
* threshold from the handbook: 75 hours, deadline April 15

### Step 1b - The same code cannot be used twice

* second attempt refused: "That code has already been used"

### Step 2 - Read the handbook in both modes

* 30 sections bundled, 20 PDF pages
* reflowed text and original pages both ship inside the app
* grade 11 threshold 75 hours (handbook page 6)

### Step 3 - Log 6.5 hours and send them for review

* approved hours unchanged at 0
* pending hours now 6.5 - shown separately, not added
* percent complete still 0.0%

### Step 4 - The counselor approves it

* 10 entries were waiting in the queue
* approved hours moved by exactly 6.5 - the entry's own hours
* pending hours back to 0
* percent complete now 8.7% of 75 (grade 11)

### Step 4b - Approved hours are permanent

* editing refused: "Approved hours are permanent. Ask your counselor for a correction."
* deleting refused: "Approved hours are permanent and cannot be deleted."
* the row is unchanged at 6.5 hours, status approved

### Step 5 - The counselor's roster

* 53 students in total
* filtered to grade 11: 4
* filtered to last names A-C: 15 (Alderwood, Ashford, Ashford, Ashford, Ashford, Birchfield, Brookvale, Brookvale, Brookvale, Brookvale, Cedarholm, Clearwater, Clearwater, Clearwater, Clearwater)
* CSV export: 53 rows plus a header

### Step 5b - The export carries the hours just approved

* Mapleton and 6.5 both appear in the exported CSV

### Step 6 - A student sees only their own record

* roster refused: forbidden
* roster CSV refused: forbidden
* invite codes refused: forbidden
* their own entries list contains 1 entries, all their own

### Step 7 - Everything is recorded

* audit trail for this entry: entry.created -> entry.submitted -> entry.approved

## Screenshots

* `step2-handbook-iphone.png` - the handbook on iPhone
* `step5-roster-ipad.png` - the same app on iPad, with the sidebar layout

Home and dark-mode screenshots for both device families are in the parent
`verification/` directory.

**All 10 steps passed.**
