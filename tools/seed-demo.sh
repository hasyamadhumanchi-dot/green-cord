#!/bin/bash
# Build a clean demo environment: fresh database, counselor account, synthetic
# students across grades 9-12 in four different states, and a batch of spare
# invite codes. Every name is invented; no real student data is used.
#
#   tools/seed-demo.sh [--keep-running]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB="$ROOT/build/greencord-demo.db"
PORT="${GREENCORD_PORT:-8443}"
KEEP=0
[ "${1:-}" = "--keep-running" ] && KEEP=1

"$ROOT/tools/gen-certs.sh" >/dev/null

echo "==> Fresh database at $DB"
rm -f "$DB" "$DB-wal" "$DB-shm"
mkdir -p "$ROOT/build"

echo "==> Provisioning the counselor account (server-side, never over HTTP)"
python3 "$ROOT/tools/provision-counselor.py" --db "$DB" \
  --name "Green Cord Coordinator" --username counselor --password counselorpass1

echo "==> Starting the backend on https://127.0.0.1:$PORT"
python3 "$ROOT/backend/server.py" --db "$DB" --port "$PORT" &
SERVER_PID=$!
cleanup() { [ "$KEEP" -eq 0 ] && kill "$SERVER_PID" 2>/dev/null || true; }
trap cleanup EXIT

for _ in $(seq 1 60); do
  curl -sk --max-time 2 "https://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.2
done

echo "==> Seeding"
python3 "$ROOT/tools/seed_demo.py" --base "https://127.0.0.1:$PORT" \
  --cert "$ROOT/build/certs/server.crt"

if [ "$KEEP" -eq 1 ]; then
  trap - EXIT
  echo
  echo "Backend still running (pid $SERVER_PID) on https://127.0.0.1:$PORT"
  echo "Counselor sign-in: counselor / counselorpass1"
  echo "Any demo student:  <username> / demopassword1"
  echo "Stop it with: kill $SERVER_PID"
fi
