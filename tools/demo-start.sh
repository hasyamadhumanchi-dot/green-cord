#!/bin/bash
# Everything needed to demo, in one command.
#
#   tools/demo-start.sh
#
# Starts the backend with fresh demo data, installs the app on an iPhone and an
# iPad simulator, makes both trust the local certificate, and prints the logins
# and invite codes to read off during the demo.
#
# Leave this terminal window open. The backend runs until you close it or press
# Ctrl-C.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE="net.princetonisd.pshs.greencord"
PORT="${GREENCORD_PORT:-8443}"
IPHONE_NAME="${GREENCORD_IPHONE:-iPhone 18 Pro}"
IPAD_NAME="${GREENCORD_IPAD:-iPad Pro 13-inch (M5)}"

udid_for() {
  xcrun simctl list devices available -j | python3 -c "
import json, sys
want = sys.argv[1]
data = json.load(sys.stdin)
for devices in data['devices'].values():
    for device in devices:
        if device['name'] == want:
            print(device['udid']); sys.exit(0)
sys.exit(1)
" "$1"
}

echo "==> Stopping anything already running on port $PORT"
pkill -f "backend/server.py" 2>/dev/null || true
sleep 1

echo "==> Fresh backend and demo data"
tools/seed-demo.sh --keep-running > "$ROOT/build/demo-server.log" 2>&1 &
for _ in $(seq 1 90); do
  curl -sk --max-time 2 "https://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sk --max-time 2 "https://127.0.0.1:$PORT/health" >/dev/null \
  || { echo "the backend did not come up - see build/demo-server.log"; exit 1; }
# Seeding runs after the server is reachable, so wait for the roster to fill.
for _ in $(seq 1 60); do
  COUNT=$(curl -sk --max-time 2 -X POST "https://127.0.0.1:$PORT/auth/login" \
    -H 'Content-Type: application/json' \
    -d '{"username":"counselor","password":"counselorpass1"}' 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])" 2>/dev/null) || true
  [ -n "${COUNT:-}" ] && break
  sleep 1
done
echo "    backend up on https://127.0.0.1:$PORT"

echo "==> Preparing the simulators"
APP_IPHONE="$ROOT/.build/check/Build/Products/Debug-iphonesimulator/GreenCordHandbook.app"
APP_IPAD="$ROOT/.build/ipad/Build/Products/Debug-iphonesimulator/GreenCordHandbook.app"
[ -d "$APP_IPHONE" ] || { echo "no iPhone build - run the build first (see DEMO.md)"; exit 1; }
[ -d "$APP_IPAD" ] || APP_IPAD="$APP_IPHONE"

# One flaky simulator must not abort the morning, so every step here is
# tolerant and the whole device is retried before it is given up on.
prepare_device() {
  local name="$1" app="$2" udid attempt
  udid=$(udid_for "$name" 2>/dev/null) || { echo "    no simulator called '$name' - skipping"; return 1; }

  for attempt in 1 2 3; do
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    # CoreSimulator can report a device booted before it will accept installs,
    # which is the "(ipc/mig) server died" failure this retry exists for.
    xcrun simctl bootstatus "$udid" >/dev/null 2>&1 || true
    sleep 2
    xcrun simctl keychain "$udid" add-root-cert "$ROOT/build/certs/server.crt" >/dev/null 2>&1 || true
    if xcrun simctl install "$udid" "$app" >/dev/null 2>&1; then
      xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1 || true
      xcrun simctl launch "$udid" "$BUNDLE" >/dev/null 2>&1 || true
      echo "    $name ready"
      return 0
    fi
    echo "    $name did not take the app (attempt $attempt of 3), retrying"
    sleep 3
  done

  echo "    $name could not be prepared - open it in Simulator and run this again"
  return 1
}

prepare_device "$IPHONE_NAME" "$APP_IPHONE" || true
prepare_device "$IPAD_NAME" "$APP_IPAD" || true
open -a Simulator >/dev/null 2>&1 || true

TOKEN=$(curl -sk -X POST "https://127.0.0.1:$PORT/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"counselor","password":"counselorpass1"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

cat <<'BANNER'

==============================================================
  READY
==============================================================
BANNER

echo "Sign-ins"
echo "  Counselor (iPad)   counselor          counselorpass1"
echo "  Student (iPhone)   golf.gumtree       demopassword1    grade 11, hours pending"
echo "  Student            bravo.birchfield   demopassword1    grade 9, has a draft"
echo "  Student            lima.larchmont     demopassword1    grade 12, finished"
echo
echo "Invite codes for step 1 - the name is the point, read it out:"
curl -sk "https://127.0.0.1:$PORT/invite-codes" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "
import sys, json
codes = [c for c in json.load(sys.stdin)['codes'] if c['state'] == 'outstanding'][:4]
for c in codes:
    print(f\"  {c['code']}   {c['firstName']} {c['lastName']}, grade {c['grade']}\")
"
echo
echo "The script is DEMO.md. Leave this window open - closing it stops the backend."
echo "Press Ctrl-C when you are finished."
echo

# Hold the window open so the backend keeps running.
wait
