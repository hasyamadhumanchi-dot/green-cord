#!/bin/bash
# Self-signed TLS certificate for the local prototype backend.
# Production runs behind Supabase's own certificate; this exists only so the
# prototype speaks HTTPS on a laptop and never plain HTTP.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/build/certs"
mkdir -p "$DIR"
# A phone cannot reach the Mac on 127.0.0.1 - that address is the phone
# itself - so the certificate also has to cover this machine's LAN address.
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
SAN="DNS:localhost,IP:127.0.0.1"
if [ -n "$LAN_IP" ]; then
  SAN="$SAN,IP:$LAN_IP"
fi

if [ -f "$DIR/server.crt" ] && [ -f "$DIR/server.key" ] && [ "${1:-}" != "--force" ]; then
  CURRENT_SAN="$(openssl x509 -in "$DIR/server.crt" -noout -text | grep -A1 'Subject Alternative Name' | tail -1 | tr -d ' ')"
  if [ -z "$LAN_IP" ] || printf '%s' "$CURRENT_SAN" | grep -q "$LAN_IP"; then
    echo "certificate already present at $DIR (covers $CURRENT_SAN)"
    exit 0
  fi
  echo "re-issuing: the certificate does not cover this machine's address $LAN_IP"
fi

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$DIR/server.key" -out "$DIR/server.crt" \
  -days 365 -subj "/CN=localhost/O=Green Cord prototype" \
  -addext "subjectAltName=$SAN" 2>/dev/null
chmod 600 "$DIR/server.key"
echo "wrote $DIR/server.crt and $DIR/server.key"
echo "  covers: $SAN"
