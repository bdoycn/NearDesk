#!/bin/sh
# Create once a stable codesign identity so TCC grants survive rebuilds.
set -eu

CN="NearDesk Spike Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
WORKDIR="${TMPDIR:-/tmp}/neardesk-codesign-$$"

if security find-identity -v -p codesigning 2>/dev/null | grep -F "$CN" >/dev/null; then
  echo "codesign identity already present: $CN"
  security find-identity -v -p codesigning | grep -F "$CN" || true
  exit 0
fi

mkdir -p "$WORKDIR"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

cat > "$WORKDIR/codesign.ext" <<'EXT'
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=codeSigning
EXT

openssl genrsa -out "$WORKDIR/neardesk.key" 2048
openssl req -new -key "$WORKDIR/neardesk.key" -out "$WORKDIR/neardesk.csr" -subj "/CN=${CN}"
openssl x509 -req -days 3650 \
  -in "$WORKDIR/neardesk.csr" \
  -signkey "$WORKDIR/neardesk.key" \
  -out "$WORKDIR/neardesk.crt" \
  -extfile "$WORKDIR/codesign.ext"

openssl pkcs12 -export -passout pass:neardesk \
  -inkey "$WORKDIR/neardesk.key" \
  -in "$WORKDIR/neardesk.crt" \
  -out "$WORKDIR/neardesk.p12" \
  -name "$CN"

security import "$WORKDIR/neardesk.p12" -k "$KEYCHAIN" -P neardesk \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Mark cert trusted for code signing in the user trust domain (no admin/sudo).
# macOS otherwise reports CSSMERR_TP_NOT_TRUSTED and find-identity shows 0 valid.
security add-trusted-cert -r trustAsRoot -p codeSign -k "$KEYCHAIN" \
  "$WORKDIR/neardesk.crt" 2>/dev/null \
  || security add-trusted-cert -r unrestricted -p codeSign -k "$KEYCHAIN" \
       "$WORKDIR/neardesk.crt" 2>/dev/null \
  || true

security set-key-partition-list -S apple-tool:,apple:,codesign: -D "$CN" -t private 2>/dev/null || true

if ! security find-identity -v -p codesigning 2>/dev/null | grep -F "$CN" >/dev/null; then
  echo "error: identity imported but not valid for codesign yet." >&2
  echo "In Keychain Access → login → certificate '$CN' → Get Info → Trust →" >&2
  echo "  Code Signing: Always Trust. Then re-run this script." >&2
  security find-identity -p codesigning || true
  exit 1
fi

echo "installed codesign identity: $CN"
security find-identity -v -p codesigning | grep -F "$CN" || true
