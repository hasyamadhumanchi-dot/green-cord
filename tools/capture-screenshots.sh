#!/bin/bash
# Install and launch the app on an iPhone and an iPad simulator, confirm the
# process is still alive after five seconds, and capture light- and dark-mode
# screenshots. Fails if either device crashes or produces a crash report.
#
#   tools/capture-screenshots.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/verification"
BUNDLE_ID="net.princetonisd.pshs.greencord"
IPHONE="${GREENCORD_IPHONE:-iPhone 17}"
IPAD="${GREENCORD_IPAD:-iPad Pro 13-inch (M5)}"

mkdir -p "$OUT"
FAILURES=0

capture() {
  local device_name="$1" prefix="$2" derived="$3"
  echo
  echo "=============================================================="
  echo "  $device_name"
  echo "=============================================================="

  local udid
  udid=$(xcrun simctl list devices available -j \
    | python3 -c "
import json,sys
data = json.load(sys.stdin)
for runtime, devices in data['devices'].items():
    for device in devices:
        if device['name'] == '''$device_name''' and device.get('isAvailable'):
            print(device['udid'])
            raise SystemExit
raise SystemExit('device not found: $device_name')
")
  echo "udid: $udid"

  local app
  app=$(find "$derived/Build/Products" -name "GreenCordHandbook.app" -maxdepth 3 | head -1)
  [ -n "$app" ] || { echo "  FAIL: no built app under $derived"; FAILURES=$((FAILURES+1)); return; }
  echo "app:  $app"

  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true

  # Start from a clean slate so a screenshot never shows a previous run's state.
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$udid" "$app"

  # Note the crash reports that already exist, so only new ones count.
  local crash_dir="$HOME/Library/Logs/DiagnosticReports"
  local before
  before=$(ls "$crash_dir" 2>/dev/null | grep -c "GreenCordHandbook" || true)

  for appearance in light dark; do
    xcrun simctl ui "$udid" appearance "$appearance" >/dev/null 2>&1 || true
    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true

    local pid
    pid=$(xcrun simctl launch "$udid" "$BUNDLE_ID" | awk -F': ' '{print $2}')
    echo "  $appearance mode: launched pid $pid"

    # Alive after five seconds, not just alive at launch.
    sleep 5
    # Captured first rather than piped: under `set -o pipefail` a non-zero exit
    # from launchctl would fail the pipeline even when the grep matched.
    local listing
    listing=$(xcrun simctl spawn "$udid" launchctl list 2>/dev/null || true)
    if printf '%s' "$listing" | grep -q "$BUNDLE_ID"; then
      echo "  $appearance mode: still running after 5s"
    else
      echo "  FAIL: $appearance mode: the process died within 5 seconds"
      FAILURES=$((FAILURES+1))
    fi

    local name="$OUT/$prefix-home.png"
    [ "$appearance" = "dark" ] && name="$OUT/$prefix-dark.png"
    xcrun simctl io "$udid" screenshot "$name" >/dev/null 2>&1
    if [ -s "$name" ]; then
      echo "  $appearance mode: wrote $(basename "$name") ($(wc -c < "$name" | tr -d ' ') bytes)"
    else
      echo "  FAIL: $appearance mode: no screenshot written"
      FAILURES=$((FAILURES+1))
    fi
  done

  xcrun simctl ui "$udid" appearance light >/dev/null 2>&1 || true

  local after
  after=$(ls "$crash_dir" 2>/dev/null | grep -c "GreenCordHandbook" || true)
  if [ "$after" -gt "$before" ]; then
    echo "  FAIL: $((after - before)) new crash report(s) in $crash_dir"
    FAILURES=$((FAILURES+1))
  else
    echo "  no new crash reports"
  fi

  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
}

capture "$IPHONE" "iphone" "$ROOT/.build/dd"
capture "$IPAD"   "ipad"   "$ROOT/.build/dd-ipad"

echo
echo "=============================================================="
ls -la "$OUT"/*.png 2>/dev/null || true
echo
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failure(s)"
  exit 1
fi
echo "Both device families launched cleanly and were captured."
