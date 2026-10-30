#!/bin/sh
# Package the SwiftPM executable as a stably signed .app so TCC can keep
# Screen Recording / Accessibility across rebuilds (bundle id dev.neardesk.spike).
# Requires Scripts/ensure-codesign-identity.sh once (creates "NearDesk Spike Dev").
set -eu
cd "$(dirname "$0")/.."

CN="NearDesk Spike Dev"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -F "$CN" >/dev/null; then
  echo "no stable codesign identity; running Scripts/ensure-codesign-identity.sh" >&2
  Scripts/ensure-codesign-identity.sh
fi

IDENTITY=$(security find-identity -v -p codesigning | grep -F "$CN" | head -1 | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([A-F0-9]+)[[:space:]]+.*/\1/')
if [ -z "$IDENTITY" ]; then
  echo "error: could not resolve identity for $CN" >&2
  exit 1
fi

swift build
BIN="$(swift build --show-bin-path)/NearDesk"
APP=".build/NearDesk.app"
MACOS_DIR="$APP/Contents/MacOS"
mkdir -p "$MACOS_DIR"
# Keep bundle shell; replace binary + Info.plist in place to reduce path churn.
cp "$BIN" "$MACOS_DIR/NearDesk"
cp "Sources/NearDesk/Info.plist" "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" --identifier dev.neardesk.spike --options runtime "$APP" 2>/dev/null \
  || codesign --force --sign "$IDENTITY" --identifier dev.neardesk.spike "$APP"

echo "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Authority|Identifier|Signature|TeamIdentifier|Flags' || true
