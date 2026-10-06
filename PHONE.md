# Running it on your own iPhone

Step by step. Roughly 15 minutes the first time.

**You do not need the $99 Apple Developer Program.** A free Apple ID can install
an app on your own device. The only catch is that it stops working after seven
days and you plug in and hit Run again.

---

## Read this first

**You need both parts.** The app is gated behind sign-in — the handbook included,
because these are school records — so there is no longer a reading-only mode that
runs without a server. Part A puts the app on your phone; Part B gives it a
backend to sign in against.

Once you *have* signed in, the app keeps you signed in and the handbook, your
logged hours and the requirements all work with no network at all — on a bus, at
school with no Wi-Fi. It is only the first sign-in that needs the server
reachable.

| | **Part A alone** | **Parts A + B** |
| --- | --- | --- |
| App installed on your phone | yes | yes |
| Sign in, handbook, log hours, approval, roster | no | yes |
| Needs the server running | — | yes |
| Needs a certificate installed on your phone | — | yes |

**Do Part A then Part B** to demo the hour-logging and approval on
the phone itself. Be aware Part B only works while your phone and this Mac are
on the same Wi-Fi.

A third option, and honestly the easiest for showing the counselor: put the
handbook on your phone with Part A, and do the accounts half on the Simulator on
your laptop, where it already works. No certificates, nothing to go wrong.

---

# Part A — the app on your phone

## 1. Sign in to Xcode with your Apple ID

Xcode → **Settings** (⌘,) → **Accounts** → **+** → **Apple ID** → sign in.

Any Apple ID works. It does not have to be a paid developer account.

## 2. Find your Team ID

Still in **Settings → Accounts**, select your Apple ID. The team is listed on the
right, usually as `Your Name (Personal Team)`.

Click it, then **Manage Certificates…**, or look at the **Team ID** column. It is
ten characters, something like `A1B2C3D4E5`.

If you cannot find it, skip to step 3 and use the Xcode route noted there.

## 3. Regenerate the project with your team and your own bundle id

```bash
cd /Users/hasya/Documents/greencord

GREENCORD_TEAM_ID=A1B2C3D4E5 \
GREENCORD_BUNDLE_ID=com.yourname.greencord \
  python3 tools/generate_xcodeproj.py
```

Replace both values.

**Change the bundle id.** The default is `net.princetonisd.pshs.greencord`, which
claims the district's namespace. Registering that under your personal Apple ID is
exactly the thing RELEASE.md flags as a problem. `com.yourname.greencord` is
fine.

*If you could not find your Team ID:* run the command with only
`GREENCORD_BUNDLE_ID`, then open the project in Xcode, select the
**GreenCordHandbook** target → **Signing & Capabilities** → tick **Automatically
manage signing** → pick your team from the dropdown. Xcode will fill it in. Note
that re-running the generator wipes that, so prefer the environment-variable
route once you know the id.

## 4. Plug your phone in

Cable is easiest the first time. Unlock the phone and tap **Trust This Computer**
if asked.

## 5. Build and run

Open the project if it is not already open:

```bash
open /Users/hasya/Documents/greencord/GreenCordHandbook.xcodeproj
```

In the device dropdown at the top of the Xcode window (next to the scheme), pick
**your iPhone** rather than a simulator. Press **⌘R**.

## 6. Trust the app on your phone

The first launch fails with *"Untrusted Developer"*. That is expected.

On the phone: **Settings → General → VPN & Device Management → Developer App →**
your Apple ID → **Trust**.

Then tap the app icon on your home screen, or press ⌘R in Xcode again.

**The app is now on your phone.** It will open on Log In / Create Account and
stop there until it has a backend to talk to, which is Part B.

Keep going.

---

# Part B — connecting it to the backend

Only if you want sign-in, hour logging and approval on the phone.

## 7. Check this Mac's address

```bash
ipconfig getifaddr en0
```

Note the number. As of writing this, yours is **192.168.1.177**.

**It changes when you join a different Wi-Fi network.** Every step below depends
on it, so re-check it if anything stops working.

## 8. Reissue the certificate for that address

```bash
cd /Users/hasya/Documents/greencord
tools/gen-certs.sh
```

It detects whether the current certificate already covers your address and only
reissues if it does not. It will tell you what the certificate covers.

**If it reissues, any simulator that trusted the old one stops working.** Fix
those with:

```bash
xcrun simctl keychain booted add-root-cert build/certs/server.crt
```

and relaunch the app on them.

## 9. Start the backend so your phone can reach it

```bash
cd /Users/hasya/Documents/greencord
python3 backend/server.py --db build/greencord-walkthrough.db --port 8443 --bind 0.0.0.0
```

Leave that terminal open. `--bind 0.0.0.0` is what makes it reachable from
another device.

**Only do this on a network you trust — your home Wi-Fi, not the school's.** It
puts the server in front of everyone on that network. They would still need a
valid invite code or a password, but that is not a boundary worth testing with
anything real in the database.

Check it from the Mac first:

```bash
curl -k https://192.168.1.177:8443/health
```

Expect `{"ok": true, "service": "greencord"}`.

## 10. Install the certificate on your phone

Your phone will not talk to the server until it trusts the certificate. This is
two separate steps and **people miss the second one**.

**10a. Get the file onto the phone.** AirDrop it:

```bash
open /Users/hasya/Documents/greencord/build/certs
```

Right-click `server.crt` → **Share** → **AirDrop** → your phone.

**10b. Install it.** On the phone: **Settings** → **Profile Downloaded** near the
top → **Install** → enter your passcode → **Install** again.

**10c. Trust it.** This is the step that gets missed. **Settings → General →
About → Certificate Trust Settings** → turn the switch on for **Green Cord
prototype**.

Without 10c the certificate is installed but not trusted, and the app reports
"offline" with nothing in the server log.

## 11. Point the app at the server

In Xcode: **Product → Scheme → Edit Scheme…** (⌘<) → **Run** → **Arguments** tab
→ **Environment Variables**.

There is already a `GREENCORD_BACKEND_URL` set to `https://127.0.0.1:8443`.
Change the value to:

```
https://192.168.1.177:8443
```

Use your own address from step 7. `127.0.0.1` means "this device", so on a phone
it points the app at the phone itself and will never work.

Press **⌘R**.

## 12. Sign in

**Account** tab → **I already have an account**.

| Who | Username | Password |
| --- | --- | --- |
| Counselor | `counselor` | `counselorpass1` |
| Grade 12, finished | `lima.larchmont` | `demopassword1` |
| Grade 11, hours pending | `golf.gumtree` | `demopassword1` |
| Grade 9, nothing logged | `alpha.alderwood` | `demopassword1` |

Or use an invite code — run this for the current list:

```bash
sqlite3 build/greencord-walkthrough.db \
  "SELECT code FROM invite_codes WHERE redeemed_by IS NULL AND revoked_at IS NULL;"
```

---

# When something does not work

Work down this list. It is ordered by how often each one is the cause.

### "You are offline" when signing in

1. **Is the server running?** `curl -k https://127.0.0.1:8443/health` on the Mac.
   If not, step 9.
2. **Did you do step 10c?** Installing the certificate is not the same as
   trusting it. Settings → General → About → Certificate Trust Settings.
3. **Is the URL right?** Step 11. `127.0.0.1` on a phone points at the phone.
4. **Same Wi-Fi?** Both devices, same network. Phone not on cellular.
5. **Did the address change?** `ipconfig getifaddr en0`. If it differs from what
   is in the scheme, redo steps 7 to 11.

To see whether the phone is reaching the Mac at all, restart the server with
logging on:

```bash
GREENCORD_VERBOSE=1 python3 backend/server.py \
  --db build/greencord-walkthrough.db --port 8443 --bind 0.0.0.0
```

Every request now prints. If you sign in on the phone and nothing appears, the
phone is not reaching the Mac — that is 2, 4 or 5 above. If requests appear but
the app still complains, the problem is in the app, not the connection.

### "Untrusted Developer" on launch

Step 6. It happens once per Apple ID per device.

### The app was working and now will not open

A free Apple ID signs apps for **seven days**. Plug in, press ⌘R, done.

### "Failed to register bundle identifier"

Someone else has registered that bundle id. Pick another in step 3 —
`com.yourname.greencord2` is fine.

### Xcode shows no scheme, or Run is greyed out

Close the project and reopen it. Xcode caches schemes, and the generator rewrites
them.

### You are in the wrong project

`GreenCord.xcodeproj` is the empty Xcode template from your first commit — it
shows "Hello, world!". The app is **`GreenCordHandbook.xcodeproj`**.

---

# What this does not get you

Running on your own phone with a free Apple ID is not distribution. Nobody else
can install it this way.

To put it on the counselor's phone or club members' phones you need TestFlight,
which needs the $99 Apple Developer Program, and — before anything is published
under your personal account carrying the district's name — the written
authorization described in `RELEASE.md`. That remains the real blocker, and no
amount of setup here changes it.
