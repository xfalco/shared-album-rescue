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
# Prefer a real Apple Development identity when one exists: the signature stays
# stable across rebuilds (TCC grants persist) and the daemon trusts it more than
# an ad-hoc one. Falls back to ad-hoc ("-") on machines without a certificate.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="-"
    echo "No Apple Development identity found — signing ad hoc (Photos prompt will repeat per rebuild)."
else
    echo "Signing as: $SIGN_ID"
fi
codesign --force --sign "$SIGN_ID" \
    --identifier com.xavierfalco.shared-album-rescue \
    --entitlements Support/SharedAlbumRescue.entitlements \
    "$APP"

# Register with LaunchServices so the system knows this bundle identity.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/$APP"

echo
echo "Built $APP"
echo "Run PhotoKit commands through LaunchServices, e.g.:"
echo "  ./Scripts/run.sh download --limit 20"
echo
echo "Note: the ad-hoc signature changes on every rebuild, so macOS re-asks the"
echo "Photos permission question after rebuilding. Approve it once per build."
