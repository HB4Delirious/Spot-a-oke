#!/bin/bash
# Packages the built app into a drag-to-install DMG.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Karaoke.app"
VOL="Spot-a-oke"
DMG="build/Spot-a-oke.dmg"

[[ -d "$APP" ]] || { echo "error: $APP not found — run ./build.sh first" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"    # drag-to-install target

# A volume icon needs both the file and the Finder "has custom icon" bit; the
# bit can only be set on a writable volume, so build read-write then compress.
if [[ -f Icon/Karaoke.icns ]]; then
    cp Icon/Karaoke.icns "$STAGE/.VolumeIcon.icns"
fi

RW=$(mktemp -u).dmg
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -quiet "$RW"

MOUNT=$(mktemp -d)
hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT" "$RW"
[[ -f "$MOUNT/.VolumeIcon.icns" ]] && SetFile -a C "$MOUNT"
hdiutil detach -quiet "$MOUNT"
rmdir "$MOUNT" 2>/dev/null || true

hdiutil convert "$RW" -format UDZO -quiet -o "$DMG"
rm -f "$RW"
echo "==> Built $DMG"
ls -lh "$DMG" | awk '{print "    size: " $5}'
