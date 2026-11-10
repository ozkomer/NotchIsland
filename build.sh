#!/bin/zsh
# Builds NotchIsland.app next to this script. Usage: ./build.sh [--run]
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="NotchIsland.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotchIsland "$APP/Contents/MacOS/NotchIsland"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>NotchIsland</string>
    <key>CFBundleIdentifier</key><string>local.notchisland</string>
    <key>CFBundleExecutable</key><string>NotchIsland</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>NotchIsland, sıradaki takvim etkinliğini adada göstermek için takviminizi okur.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>NotchIsland, çalan parçayı göstermek ve oynatmayı kontrol etmek için Music ve Spotify ile konuşur.</string>
</dict>
</plist>
PLIST

# Ad-hoc signing: macOS asks for the Automation permissions again after a rebuild.
codesign --force --sign - "$APP"
# `notch` command: the same binary, used by scripts to show activities.
cat > notch <<SCRIPT
#!/bin/zsh
exec "$PWD/$APP/Contents/MacOS/NotchIsland" "\$@"
SCRIPT
chmod +x notch

echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x NotchIsland 2>/dev/null || true
    open "$APP"
fi
