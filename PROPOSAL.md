# Green Cord app — a prototype, and what I'm asking for

**For:** the Green Cord Coordinator, Princeton Senior High School
**From:** a PHS student
**Date:** 20 September 2026

---

## What this is

A working iPhone and iPad app for the Green Cord program. Not a mockup — every
part of it runs. You can hold it, tap it, approve hours in it.

You asked me to build a prototype and bring it back before anything goes further.
This is that prototype, and this page is the ask.

---

## What it does

**Students read the handbook in the app.** All twenty pages, either as text that
resizes for whoever is reading it or as the original pages exactly as they are
printed. Search finds a phrase and shows both the section and the page number. It
works with no signal.

**Students log their hours in the app.** Date, hours, category, organization,
what they did, and the supervisor who signs the form — the same fields the
Community Service Verification Form asks for. They can attach a photo of the
signed form.

**Nothing counts until you approve it.** An entry arrives in your queue. You open
it, see the evidence, and approve it, decline it, or send it back with a note.
Only then does it count toward the student's total.

**Approved hours are permanent.** Once you approve an entry, the student cannot
edit or delete it. If a correction is needed, you make it, and the original
values stay in a history log that cannot be erased.

**Students see their own record and nothing else.** No roster, no ranking, no way
to see another student's hours. That is enforced on the server, not just hidden
in the app.

**You see everyone.** A sortable list of every student with their grade, approved
hours, hours waiting on you, and percent complete against their own grade's
requirement. Filter by grade or by last-name range. Export to a spreadsheet in
one tap.

**It knows the handbook's rules.** 25 hours for freshmen, 50 for sophomores, 75
for juniors, 100 for seniors. 60-hour cap on school-based service, 40 on
faith-based, 40 per organization, three organizations for the senior award. April
15 for grades 9–11, April 1 for seniors. Every one of those numbers was read out
of the handbook PDF and carries the page it came from — **nothing was invented.**
Where the handbook does not say something, the app says "not specified in the
handbook" rather than guessing.

**You can log hours for students.** For paper forms handed in at the office. Those
entries are marked as entered by you.

**You add students; they sign up with the code you gave them.** You enter a
student's name and grade — one at a time, or paste your whole list — and each one
gets their own code. Print them on slips, hand them out at a meeting.

Because the code is theirs, a student never types their own name: they enter the
code, see "this is for Jordan Martinez, grade 11", and confirm. So the roster is
your list, not whatever people typed about themselves, and nobody can enrol under
someone else's name or pick their own grade. Students you have added but who
haven't signed up yet show on the roster as "not joined", so you can see who is
behind and who simply hasn't opened the app.

Each code works once and expires after 30 days. There is no other way to make an
account — nobody can sign themselves up, and no student account can turn itself
into a counselor account.

**Updating the handbook does not need a new app.** When you revise it, the new
version is uploaded to the school website and every installed copy picks it up.
No App Store submission, no waiting.

---

## What it stores, and where

Only what the approval workflow needs:

* The student's name, their grade, and a username
* For each entry: date, hours, category, organization, what they did, the
  supervisor's name and contact, and optionally a photo of the signed form
* Who approved what and when

That is all. **No analytics, no advertising, no tracking of any kind** — there
are no third-party components in the app at all. Everything travels encrypted.

**Who can see what:**

| | Their own record | Any other student | Everyone |
| --- | --- | --- | --- |
| A student | Yes | **No** | **No** |
| You | Yes | Yes | Yes |

A student can delete their account from inside the app. That erases their name
and the details they typed; the hours stay as an anonymous part of the program's
record. **Whether that is the right rule at graduation is a question for the
district, and it is on my list to ask.**

Right now this prototype runs on my laptop with twelve made-up students. **No
real student data has been entered anywhere.**

---

## What it would cost to run

The app needs a server to hold the records.

**Supabase** (supabase.com) — a hosted Postgres database with accounts built in:

| Plan | Monthly | What you get |
| --- | --- | --- |
| Free | **$0** | 500 MB database, 50,000 monthly active users, 7 days of backups |
| Pro | **$25** | 8 GB, daily backups kept 7 days, point-in-time recovery available |

For a program this size the free tier is genuinely enough on capacity — a few
hundred students and a few thousand entries a year is nowhere near 500 MB.

**My recommendation is the $25/month Pro plan anyway, for one reason: backups.**
Seven days of retention on the free tier is fine for an app; it is not enough for
a record a student builds over four years. If something goes wrong over a school
holiday, seven days may already be gone.

Publishing on the App Store would also need an **Apple Developer account at
$99/year**. TestFlight — installing it directly for you and club members without
a public listing — uses the same account.

**So: $0–25 a month, plus $99 a year if it goes on the App Store.**

---

## What I'm asking for

**1. Look at the demo.** Ten minutes. I'll show you a student logging hours, you
approving them, and the roster updating. Bring a hard case if you have one.

**2. Tell me what's wrong with it.** I built this from the handbook. You run the
program. The places where the app's idea of the rules does not match how it
actually works are the things I most need to hear.

**3. Decide whether it goes further.** If it does, there are things only the
school can settle:

* **Permission to use the district's name, the panther, and student records in an
  app.** I cannot give myself that, and Apple will ask. (The panther in the app
  right now is one I drew — the program page does not publish one — and it is
  meant to be replaced with the school's.)
* **Who owns the server and pays for it**, and who takes over the records if you
  leave PHS. A four-year academic record should not depend on one person's
  account.
* **What happens to a student's record when they graduate.**
* **Where on the school website the handbook file can live**, so updates work.

**4. If you say yes, I'd suggest TestFlight first, not the App Store.** That puts
it on your phone and a handful of students' phones without a public listing,
which lets us find the problems with real students before anything is published.

---

## What I have not done

I have not submitted this anywhere, listed it, or shown it to anyone outside this
conversation. No real student data has gone into it. That was deliberate — you
said bring it back for approval first, and this is me bringing it back.
