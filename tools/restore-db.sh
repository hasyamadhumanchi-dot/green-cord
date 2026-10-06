#!/bin/bash
# Restore a backup over a target database, after checking the backup is intact.
#
#   tools/restore-db.sh backups/greencord-....db target.db
set -euo pipefail
BACKUP="$1"
TARGET="$2"
[ -f "$BACKUP" ] || { echo "no such backup: $BACKUP" >&2; exit 1; }
echo "==> Verifying the backup"
RESULT="$(sqlite3 "$BACKUP" "PRAGMA integrity_check;" | head -1)"
[ "$RESULT" = "ok" ] || { echo "backup failed integrity check: $RESULT" >&2; exit 1; }
echo "    integrity_check: ok"
if [ -f "$TARGET" ]; then
  SAFETY="$TARGET.before-restore-$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$TARGET" "$SAFETY"
  echo "    existing database copied aside to $SAFETY"
fi
rm -f "$TARGET-wal" "$TARGET-shm"
cp "$BACKUP" "$TARGET"
echo "==> Restored $BACKUP -> $TARGET"
sqlite3 "$TARGET" "SELECT 'accounts', COUNT(*) FROM accounts
                   UNION ALL SELECT 'hour_entries', COUNT(*) FROM hour_entries
                   UNION ALL SELECT 'audit_log', COUNT(*) FROM audit_log;"
