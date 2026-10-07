#!/bin/bash
# Builds the app with the Command Line Tools swiftc -- no Xcode, no project file.
# New source files must be added to the swiftc line by hand; nothing picks them up.
set -euo pipefail
cd "$(dirname "$0")"

# ---- app identity: the only line in this file that names the app ----
NAME="SysMonitor"; DISPLAY_NAME="System Monitor"
# --------------------------------------------------------------------

BUNDLE_ID="local.ktutnik.$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')"
APP="${1:-$HOME/Applications/$NAME.app}"

rm -rf build "$APP"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
  -framework AppKit -framework SwiftUI -framework IOKit \
  -o "build/$NAME" \
  Sources/Battery.swift Sources/Chart.swift Sources/CodeSignature.swift Sources/NetDayChart.swift Sources/HistoryStore.swift Sources/Panel.swift Sources/PopoverView.swift Sources/VitalsStore.swift Sources/NetStore.swift Sources/NetView.swift Sources/TabContainer.swift Sources/main.swift

cp "build/$NAME" "$APP/Contents/MacOS/$NAME"

# The icon is committed, not generated here: see make-icon.sh. A build that had
# to render it would be a build that can ship without one when that step fails.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- menu bar only: no Dock tile, no app menu -->
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string></string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
