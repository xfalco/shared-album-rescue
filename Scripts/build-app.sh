#!/bin/bash
# Wraps the release binary in a minimal .app bundle. photolibraryd (the daemon behind
# PhotoKit) refuses XPC connections from bundle-less processes with endless
# "NSCocoaErrorDomain Code=4097" retries — running the same binary from inside an
# .app gives it a code-signing identity TCC and the daemon will accept.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="SharedAlbumRescue.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp .build/release/shared-album-rescue "$APP/Contents/MacOS/shared-album-rescue"
codesign --force --sign - --identifier com.xavierfalco.shared-album-rescue "$APP"

echo
echo "Built $APP"
echo "Run PhotoKit commands through the bundled binary, e.g.:"
echo "  ./$APP/Contents/MacOS/shared-album-rescue download --limit 20"
echo
echo "Note: the ad-hoc signature changes on every rebuild, so macOS re-asks the"
echo "Photos permission question after rebuilding. Approve it once per build."
