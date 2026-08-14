#!/bin/bash
set -euo pipefail

APP="RecordMonitor.app"
BIN="$APP/Contents/MacOS/RecordMonitor"

# Requires Xcode Command Line Tools. If swiftc is missing: xcode-select --install
command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>RecordMonitor</string>
  <key>CFBundleIdentifier</key><string>net.big0time.recordmonitor</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>RecordMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSCameraUsageDescription</key><string>Shows live video of the turntable.</string>
  <key>NSMicrophoneUsageDescription</key><string>Plays audio from the USB record player through your speakers.</string>
</dict>
</plist>
PLIST

# Icon: AppIcon.icns must sit next to this script.
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "WARNING: AppIcon.icns not found next to build.sh - app will use the generic icon."
fi

swiftc -O -target arm64-apple-macos14.0 main.swift -o "$BIN" \
  -framework Cocoa -framework AVFoundation

chmod +x "$BIN"

# Ad-hoc signature so macOS remembers the camera/mic permission grants.
codesign --force --sign - "$APP"

# Nudge Finder/Dock to pick up the new icon instead of a cached generic one.
touch "$APP"

echo "Built $APP"
echo "Run:  open $APP"
