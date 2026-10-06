#!/bin/bash
# Back up the records database. SQLite's .backup is transactionally consistent,
# so this is safe while the server is running.
#
#   tools/backup-db.sh [source.db] [backup-dir]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/build/greencord-demo.db}"
DIR="${2:-$ROOT/build/backups}"
mkdir -p "$DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$DIR/greencord-$STAMP.db"
sqlite3 "$SRC" ".backup '$OUT'"
sqlite3 "$OUT" "PRAGMA integrity_check;" | head -1
shasum -a 256 "$OUT" | awk '{print $1"  "$2}'
echo "$OUT"
