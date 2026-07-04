#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/MeetingAlert.app"
MACOS="$APP/Contents/MacOS"
BINARY="$MACOS/MeetingAlert"

mkdir -p "$MACOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.kota.meeting-alert</string>
  <key>CFBundleName</key><string>MeetingAlert</string>
  <key>CFBundleExecutable</key><string>MeetingAlert</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>会議の直前にフルスクリーンでリマインドを表示するため、カレンダーへのアクセスが必要です。</string>
</dict>
</plist>
EOF

echo "Building MeetingAlert..."
swiftc "$SCRIPT_DIR/MeetingAlert.swift" \
  -o "$BINARY" \
  -framework AppKit \
  -framework EventKit \
  -framework Foundation

codesign --force --sign - "$APP"

echo "Build complete: $APP"
echo ""
echo "Run with:  open '$APP'"
