#!/bin/bash
# Builds Karaoke.app with only the Swift toolchain — no Xcode required.
#
# Xcode is the normal path (see project.yml), but Command Line Tools alone can
# compile, link, bundle and sign this app. The one catch: SwiftUI's @State is a
# macro in the macOS 27 SDK and the macro plugin ships only with Xcode, so we
# build against the newest installed SDK that still predates that change.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Karaoke"
BUNDLE_ID="com.logan.SpotifyKaraoke"
DEPLOY_TARGET="14.0"
OUT="${1:-./build}"

# Pick an SDK whose SwiftUI does not require the Xcode-only macro plugin.
SDK_ROOT="/Library/Developer/CommandLineTools/SDKs"
SDK=""
for candidate in MacOSX26.5.sdk MacOSX26.sdk; do
    if [[ -d "$SDK_ROOT/$candidate" ]]; then SDK="$SDK_ROOT/$candidate"; break; fi
done
if [[ -z "$SDK" ]]; then
    echo "error: no macOS 26.x SDK found under $SDK_ROOT" >&2
    echo "       Newer SDKs need Xcode for SwiftUI macro expansion." >&2
    exit 1
fi
echo "==> SDK: $(basename "$SDK")"

APP="$OUT/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling"
swiftc \
    -swift-version 5 \
    -target "arm64-apple-macosx$DEPLOY_TARGET" \
    -sdk "$SDK" \
    -O \
    -o "$APP/Contents/MacOS/$APP_NAME" \
    ./*.swift

echo "==> Bundling"
cp Info.plist "$APP/Contents/Info.plist"

echo "==> Signing (ad-hoc, hardened runtime + Apple Events entitlement)"
codesign --force --sign - \
    --options runtime \
    --entitlements Karaoke.entitlements \
    --timestamp=none \
    "$APP"

echo "==> Built $APP"
codesign -dv "$APP" 2>&1 | grep -E "flags|Signature" || true
