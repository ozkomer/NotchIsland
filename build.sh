#!/bin/zsh
# Builds NotchIsland.app next to this script.
# Usage: ./build.sh [--run | --install]
#   --run      start the freshly built copy
#   --install  copy it to /Applications and start it from there
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="NotchIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchIsland "$APP/Contents/MacOS/NotchIsland"
# The icon is drawn by Tools/make-icon.swift.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>NotchIsland</string>
    <key>CFBundleIdentifier</key><string>local.notchisland</string>
    <key>CFBundleExecutable</key><string>NotchIsland</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>NotchIsland, sıradaki takvim etkinliğini adada göstermek için takviminizi okur.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>NotchIsland, zamanı gelen anımsatıcıyı adada göstermek için anımsatıcılarınızı okur.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>NotchIsland, çalan içeriği göstermek ve oynatmayı kontrol etmek için oynatıcılar ve tarayıcılarla konuşur.</string>
</dict>
</plist>
PLIST

# Ad-hoc signing: macOS asks for the Automation permissions again after a rebuild.
codesign --force --sign - "$APP"
# `notch` command: the same binary, used by scripts to show activities.
cat > notch <<SCRIPT
#!/bin/zsh
# Prefer the installed copy, so the command and the running app are the same program.
BIN="/Applications/$APP/Contents/MacOS/NotchIsland"
[[ -x "\$BIN" ]] || BIN="$PWD/$APP/Contents/MacOS/NotchIsland"
exec "\$BIN" "\$@"
SCRIPT
chmod +x notch

echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x NotchIsland 2>/dev/null || true
    open "$APP"
elif [[ "${1:-}" == "--install" ]]; then
    pkill -x NotchIsland 2>/dev/null || true
    rm -rf "/Applications/$APP"
    ditto "$APP" "/Applications/$APP"
    echo "Installed /Applications/$APP"
    open "/Applications/$APP"
fi
