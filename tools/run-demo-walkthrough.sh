#!/bin/bash
# Execute the DEMO.md walkthrough end to end against a live backend, capturing a
# screenshot at each step into verification/demo/.
#
# It drives the workflow through the API - redeem, log, submit, approve, verify
# the totals moved and the entry locked, filter the roster, export - and
# screenshots the app beside it, so the pictures and the data agree.
#
#   tools/run-demo-walkthrough.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/verification/demo"
PORT="${GREENCORD_PORT:-8455}"
DB="$ROOT/build/greencord-walkthrough.db"
BUNDLE_ID="net.princetonisd.pshs.greencord"
IPHONE="${GREENCORD_IPHONE:-iPhone 17}"
IPAD="${GREENCORD_IPAD:-iPad Pro 13-inch (M5)}"

mkdir -p "$OUT"
rm -f "$OUT"/*.png

echo "==> Fresh database and counselor"
rm -f "$DB" "$DB-wal" "$DB-shm"
mkdir -p "$ROOT/build"
"$ROOT/tools/gen-certs.sh" >/dev/null
python3 "$ROOT/tools/provision-counselor.py" --db "$DB" \
  --username counselor --password counselorpass1 >/dev/null
echo "    counselor provisioned"

echo "==> Backend on https://127.0.0.1:$PORT"
python3 "$ROOT/backend/server.py" --db "$DB" --port "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  curl -sk --max-time 2 "https://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.2
done

echo "==> Seeding the demo cohort"
python3 "$ROOT/tools/seed_demo.py" --base "https://127.0.0.1:$PORT" \
  --cert "$ROOT/build/certs/server.crt" >/dev/null
echo "    12 synthetic students across grades 9-12"

echo
echo "==> Driving the DEMO.md walkthrough through the API"
python3 "$ROOT/tools/demo_walkthrough.py" --base "https://127.0.0.1:$PORT" \
  --cert "$ROOT/build/certs/server.crt" --out "$OUT"

echo
echo "==> Capturing the app's screens"
capture_app() {
  local device_name="$1" prefix="$2" derived="$3"
  local udid
  udid=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
data = json.load(sys.stdin)
for runtime, devices in data['devices'].items():
    for device in devices:
        if device['name'] == '''$device_name''' and device.get('isAvailable'):
            print(device['udid']); raise SystemExit
raise SystemExit('device not found')
")
  local app
  app=$(find "$derived/Build/Products" -name "GreenCordHandbook.app" -maxdepth 3 | head -1)
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$udid" "$app"
  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
  sleep 6
  xcrun simctl io "$udid" screenshot "$OUT/$prefix.png" >/dev/null 2>&1
  echo "    wrote $prefix.png"
  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
}

capture_app "$IPHONE" "step2-handbook-iphone" "$ROOT/.build/dd"
capture_app "$IPAD"   "step5-roster-ipad"     "$ROOT/.build/dd-ipad"

echo
echo "=============================================================="
ls -la "$OUT"
echo
echo "Walkthrough complete. Screenshots and the step log are in verification/demo/."
