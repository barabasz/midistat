#!/bin/bash
# Builds build/MIDIstat.app (release, ad-hoc signed).
# With --install, also copies it to /Applications and (re)starts it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MIDIstat"
APP="build/MIDIstat.app"

rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MIDIstat"
cp Support/Info.plist "$APP/Contents/Info.plist"

"$BIN" --export-iconset build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x MIDIstat || true
    rm -rf /Applications/MIDIstat.app
    cp -R "$APP" /Applications/
    open /Applications/MIDIstat.app
    echo "Installed /Applications/MIDIstat.app"
fi
