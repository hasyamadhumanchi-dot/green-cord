# The ten-minute demo

A script for showing the prototype to the Green Cord Coordinator. It goes from a
student with nothing logged to a counselor with an exported spreadsheet, and it
shows the one thing that matters most: **hours do not count until the counselor
approves them, and once approved the student cannot change them.**

---

## Before they arrive

**One command, in a terminal window you leave open:**

```bash
cd /Users/hasya/Documents/GreenCord
tools/demo-start.sh
```

It starts the backend with fresh data, installs the app on both simulators,
makes them trust the local certificate, and prints the logins and the invite
codes to read out in step 1. **Closing that window stops the backend**, and
with it the ability to sign in.

Then check nothing embarrassing will appear:

```bash
TEST_RUNNER_GREENCORD_BACKEND_URL=https://127.0.0.1:8443 \
  xcodebuild test -project GreenCordHandbook.xcodeproj -scheme GreenCordHandbook \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -only-testing:GreenCordHandbookUITests/DemoRehearsalTests
```

Two minutes. It signs in as both roles, walks every screen, and fails on a
crash, an error banner, a false "offline" notice, developer text on screen, an
empty dashboard or an empty review queue.

---

### If you need to do it by hand

```bash
cd /Users/hasya/Documents/GreenCord

# 1. Build for both device families
xcodebuild -project GreenCordHandbook.xcodeproj -scheme GreenCordHandbook \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath .build/dd build
xcodebuild -project GreenCordHandbook.xcodeproj -scheme GreenCordHandbook \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -derivedDataPath .build/dd-ipad build

# 2. Fresh demo data and a running backend
tools/seed-demo.sh --keep-running
```

That gives you twelve invented students across grades 9–12 — some with nothing
logged, some partway, some with hours waiting on review, some finished — plus 40
students who have been issued a code but have not signed up yet, so the roster
shows both states.

Every code belongs to a named student. The seeder prints the first few
name-and-code pairs; **write one down**, with the name, because you will type it
in step 1 and the app will show you whose it is.

Point the app at the server: set `GreenCordBackendURL` in
`GreenCordHandbook/Info.plist` to `https://127.0.0.1:8443`, regenerate, rebuild.

Sign-ins:

| | Username | Password |
| --- | --- | --- |
| Counselor | `counselor` | `counselorpass1` |
| Alpha Alderwood (grade 9, nothing logged) | `alpha.alderwood` | `demopassword1` |
| Lima Larchmont (grade 12, finished) | `lima.larchmont` | `demopassword1` |

**Open two simulators side by side** — an iPhone as the student, an iPad as you.
Switching between them in front of the counselor is what makes the approval step
land.

---

## The script

### 1. Redeem a code — 2 minutes

*On the iPhone.*

Open the app. It opens on **Log In / Create Account** — nothing in the program is
reachable before signing in, the handbook included.

> "These are school records about minors, so there's no public side to this at
> all."

Tap **Create Account**. Type the code you wrote down. Tap **Continue**.

The next screen shows the student's name and grade.

> "This is the part I'd most like you to look at. You don't hand out anonymous
> codes — you add the student, and the code is theirs. So they don't type their
> own name, they confirm the one you gave them. A student can't enrol as someone
> else, can't pick their own grade, and your roster is your list rather than
> whatever people typed about themselves."

Set a username and a password. Tap **Create My Account**.

> "Each code works once and expires in 30 days — eight characters, no letter O
> and no zero, so nobody mistypes it off a slip. There's no self-signup, and no
> way for a student account to become a counselor account."

**Worth showing if they ask:** type a wrong code first. It says *"We do not
recognise that code. Check it and try again — codes have no letter O or number
0."* Not an error code.

### 2. Read the handbook — 2 minutes

**Handbook** tab. A list of the handbook's sections. Tap **SERVICE HOUR
REQUIREMENTS**.

> "It opens on your actual page 6 — your handbook, your layout, nothing retyped.
> The list is just a way of jumping to the right page."

Page back and forth; the section highlighted in the list follows along.

Now pull down and search **`Silver Service`**.

> "Search reads the text inside the PDF, so it can tell you the section and the
> page. All of this works in airplane mode — the whole handbook ships inside the
> app, and it updates from the school website without anyone reinstalling
> anything."

### 3. Log an entry — 2 minutes

*The student lands on **My Progress**, which is where they'll live.* Tap **Log
Hours**.

Fill it in as a student would: a date, hours, a category, an organization, what
they did, and the supervisor's name and contact.

> "These are the fields off your Community Service Verification Form — page 15.
> Including the supervisor's email and phone, because the handbook says you can
> contact them."

Tap **Attach a photo of the signed form**, pick anything.

> "One caveat I want to be straight about: right now this records *that* a
> form was attached, not the image itself. Storing the photos needs file
> storage on the server, which is a small piece of work I've deliberately left
> until you've said you want this."

Tap **Send for review.**

Now **My Progress**:

> "Here's the important bit. Those hours show as *awaiting review* — a separate
> number, in grey, with 'not counted yet' under it. The approved total is still
> zero. The app never adds those two together."

### 4. Approve it — 2 minutes

*Switch to the iPad.* Sign in as `counselor`.

**Review Queue.** The entry is there.

Open it. Show the description, the supervisor's details, and the marker saying
a form was attached.

> "You see everything before you decide. Three choices: approve, don't accept, or
> send it back asking for a change — with a note the student reads."

Add a note. Tap **Approve**.

*Switch back to the iPhone.* Pull to refresh on **My Progress**.

> "Now they count. The approved number moved by exactly those hours, and the
> percentage is against *their* grade's requirement — 25 for a freshman, 100 for
> a senior."

Go to **My Hours** and tap the approved entry.

> "And they can't touch it. No edit, no delete. It says approved hours are
> permanent and to come to you if something's wrong. That's enforced on the
> server, not just greyed out in the app — if someone tried to change it from
> outside the app, the server would refuse."

### 5. The roster — 2 minutes

*On the iPad.* **Students.**

> "Everyone, with approved hours, hours waiting on you, and percent complete
> against their own grade's threshold."

Filter to **Grade 12.**

> "Or by last name — A to C, say, if you're working through a stack
> alphabetically."

Set the last-name range to A–C.

Tap **Export CSV.**

> "That's a spreadsheet. Open it in Excel or Sheets, send it wherever it needs to
> go."

Then **Students & invite codes**:

> "This is where you add students. One at a time, or paste your whole list in —
> name and grade per line, straight out of a spreadsheet — and it issues a code
> for each of them. Export that and you have a sheet of names and codes to hand
> out."

Scroll to **Not signed up yet**.

> "And this tells you who still hasn't joined. They're on the roster from the
> moment you add them, marked 'Not joined', so you're never guessing whether a
> student is behind or just hasn't opened the app."

### 6. What a student cannot see — 1 minute

*Back on the iPhone.*

> "One last thing. There's no roster here, no leaderboard, nothing about anyone
> else. A student sees their own record and that's it — and that's a rule on the
> server, not something the app is politely hiding."

---

## Questions worth asking them

Write the answers down. Several block anything further — see RELEASE.md.

1. **Where am I wrong?** I built this from the handbook. Where does the app's
   idea of the rules not match how the program actually runs?
2. **What happens at graduation** — is a student's record deleted, handed to you,
   or kept?
3. **Would you want this at all**, or is the Google Form working fine?
4. **Who would own the server** and its $0–25 a month, and who takes the records
   if you leave PHS?
5. **Can the school authorize** using the district's name and the panther, and
   students' records, in an app?
6. **Where on the school website could a file live** so the handbook updates
   without an app update?
7. **Is this the right logo to use?** The app now carries the official Princeton
   ISD panther. The copy supplied is 554px with no transparent background, so a
   vector or 1024px version would look sharper on a modern screen.

---

## If something breaks

* **Signing in fails** — the backend isn't running, or `GreenCordBackendURL`
  isn't set. There is no reading-only fallback any more: the app is gated behind
  sign-in, so get the server up before they arrive. `tools/seed-demo.sh
  --keep-running` does both.
* **The roster is empty** — re-run `tools/seed-demo.sh --keep-running`.
* **A simulator is slow to start** — boot both before they walk in.

---

## Screenshots

`verification/demo/` holds a screenshot from each step of this script, captured
during a full run-through, along with light and dark mode home screens for both
device families in `verification/`.
