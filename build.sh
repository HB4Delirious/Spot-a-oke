#!/bin/bash
# Builds Karaoke.app.
#
# Works with Command Line Tools alone, or with Xcode. The catch is SwiftUI's
# @State, which is a macro in the macOS 27 SDK whose plugin ships only with
# Xcode — so when only CLT is present we build against the newest installed SDK
# that predates that change. With Xcode selected, its own SDK is used instead.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Karaoke"
BUNDLE_ID="com.logan.SpotifyKaraoke"
DEPLOY_TARGET="14.0"
OUT="${1:-./build}"

# With Xcode selected, let swiftc choose its own SDK: `xcrun --show-sdk-path`
# can return a stale Command Line Tools path that no longer exists, and forcing
# a mismatched SDK fails with "this SDK is not supported by the compiler".
#
# Without Xcode, fall back to a macOS 26.x SDK, whose SwiftUI still predates the
# @State macro that needs the Xcode-only plugin.
SDK_ARGS=()
if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    echo "==> SDK: Xcode default"
else
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
    SDK_ARGS=(-sdk "$SDK")
    echo "==> SDK: $(basename "$SDK")"
fi

# Build into a staging bundle and swap it in only once everything succeeds.
# Deleting the working app up front means a single failed compile leaves
# nothing to run.
APP="$OUT/$APP_NAME.app"
STAGE="$OUT/.$APP_NAME.building"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Compiling"
swiftc \
    -swift-version 5 \
    -target "arm64-apple-macosx$DEPLOY_TARGET" \
    ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} \
    -O \
    -o "$STAGE/Contents/MacOS/$APP_NAME" \
    ./*.swift

echo "==> Bundling"
cp Info.plist "$STAGE/Contents/Info.plist"
if [[ -f Icon/Karaoke.icns ]]; then
    cp Icon/Karaoke.icns "$STAGE/Contents/Resources/Karaoke.icns"
else
    echo "    warning: Icon/Karaoke.icns missing — app will use the generic icon" >&2
fi

echo "==> Signing (ad-hoc, hardened runtime + Apple Events entitlement)"
codesign --force --sign - \
    --options runtime \
    --entitlements Karaoke.entitlements \
    --timestamp=none \
    "$STAGE"

# Everything worked; only now replace the previous build.
rm -rf "$APP"
mv "$STAGE" "$APP"
trap - EXIT

echo "==> Built $APP"
codesign -dv "$APP" 2>&1 | grep -E "flags|Signature" || true
