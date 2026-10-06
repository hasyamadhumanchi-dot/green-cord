#!/bin/bash
# Build the directory that gets uploaded to the school website so installed copies
# of the app pick up a new handbook. Data only - this can never deliver code.
#
#   tools/publish-content.sh [--base-url https://.../greencord-app-content/]
#
# Output: build/publish/  plus the exact upload instructions for the webmaster.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/publish"
BASE_URL="https://pshs.princetonisd.net/greencord-app-content/"

while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) BASE_URL="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

echo "==> Rebuilding content from the source PDF"
mkdir -p "$ROOT/.build"
if [ ! -x "$ROOT/.build/extract_pdf" ] || [ "$ROOT/tools/extract_pdf.swift" -nt "$ROOT/.build/extract_pdf" ]; then
  swiftc -O "$ROOT/tools/extract_pdf.swift" -o "$ROOT/.build/extract_pdf"
fi
"$ROOT/.build/extract_pdf" "$ROOT/content/source/PISDGreenCordHandbook.pdf" 2>/dev/null > "$ROOT/.build/raw.json"
python3 "$ROOT/tools/build_content.py" "$ROOT/.build/raw.json"

echo
echo "==> Verifying content against the source PDF"
python3 "$ROOT/tools/verify_content.py" > "$ROOT/.build/content-verify.log"
echo "    ok (full report: .build/content-verify.log)"

echo
echo "==> Staging upload directory"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$ROOT/content/handbook.json"      "$OUT/handbook.json"
cp "$ROOT/content/requirements.json"  "$OUT/requirements.json"
cp "$ROOT/content/source/PISDGreenCordHandbook.pdf" "$OUT/PISDGreenCordHandbook.pdf"

echo
echo "==> Writing manifest"
python3 "$ROOT/tools/build_manifest.py" "$OUT" --base-url "$BASE_URL"
# Keep the in-repo manifest in step with the staged one.
python3 "$ROOT/tools/build_manifest.py" "$ROOT/content" --base-url "$BASE_URL" >/dev/null

echo
echo "==> Validating the staged payload"
python3 "$ROOT/tools/validate_manifest.py" "$OUT"

CONTENT_VERSION=$(python3 -c "import json;print(json.load(open('$OUT/manifest.json'))['contentVersion'])")

cat <<EOF

========================================================================
UPLOAD INSTRUCTIONS FOR THE SCHOOL WEBSITE
========================================================================

Content version: $CONTENT_VERSION

Upload these four files, keeping these exact filenames, so that each is
served at the URL shown:

EOF
for f in manifest.json handbook.json requirements.json PISDGreenCordHandbook.pdf; do
  printf '  %-28s ->  %s%s\n' "build/publish/$f" "$BASE_URL" "$f"
done
cat <<EOF

The app polls only ${BASE_URL}manifest.json. Everything else is
discovered from that file, so manifest.json must be uploaded LAST - if it
arrives before the files it names, apps will try to fetch content that is
not there yet and will keep their current copy.

Requirements for the hosting path:
  * HTTPS only. The app refuses plain http:// URLs.
  * Served as static files. No login wall, no redirect to an HTML page.
  * Content-Type should be application/json and application/pdf, but the
    app verifies SHA-256 rather than trusting the header.

To publish a change: edit the Google Doc, export it to
content/source/PISDGreenCordHandbook.pdf, bump "contentVersion" in
content/handbook.json and content/requirements.json to today's date in
YYYY.MM.DD form, re-run this script, and upload the result.
========================================================================
EOF
