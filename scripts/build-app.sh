#!/bin/bash
# Builds build/MIDIstat.app (release, ad-hoc signed).
#
#   --universal  build for Apple silicon and Intel (arm64 + x86_64)
#   --install    also copy the app to /Applications and (re)start it
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=0 INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --install) INSTALL=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

APP="build/MIDIstat.app"
BIN="build/MIDIstat"
mkdir -p build

if [[ $UNIVERSAL == 1 ]]; then
    # Each architecture gets its own scratch path, otherwise they overwrite each other.
    for arch in arm64 x86_64; do
        swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch"
    done
    lipo -create -output "$BIN" \
        "$(swift build -c release --triple arm64-apple-macosx14.0 --scratch-path .build/arm64 --show-bin-path)/MIDIstat" \
        "$(swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/x86_64 --show-bin-path)/MIDIstat"
else
    swift build -c release
    cp "$(swift build -c release --show-bin-path)/MIDIstat" "$BIN"
fi

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/MIDIstat"
cp Support/Info.plist "$APP/Contents/Info.plist"

"$APP/Contents/MacOS/MIDIstat" --export-iconset build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

codesign --force --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/MIDIstat"))"

if [[ $INSTALL == 1 ]]; then
    pkill -x MIDIstat || true
    rm -rf /Applications/MIDIstat.app
    cp -R "$APP" /Applications/
    open /Applications/MIDIstat.app
    echo "Installed /Applications/MIDIstat.app"
fi
