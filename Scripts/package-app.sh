#!/bin/sh
# Package the SwiftPM executable as an ad-hoc signed .app so TCC can see
# bundle id dev.neardesk.spike. A new signature asks for permissions again.
set -eu
cd "$(dirname "$0")/.."
swift build
BIN="$(swift build --show-bin-path)/NearDesk"
APP=".build/NearDesk.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NearDesk"
cp "Sources/NearDesk/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "$APP"
