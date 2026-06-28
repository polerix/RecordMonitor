#!/bin/bash
set -euo pipefail

NAME="RecordMonitor"
APP="$NAME.app"
DIST="dist"

# Requires Xcode Command Line Tools. If swiftc is missing: xcode-select --install
command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install"; exit 1; }

# Shared Info.plist for every bundle we assemble.
write_plist() {
  cat > "$1/Contents/Info.plist" <<'PLIST'
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
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSCameraUsageDescription</key><string>Shows live video of the turntable.</string>
  <key>NSMicrophoneUsageDescription</key><string>Plays audio from the USB record player through your speakers.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Captures system audio to drive the visualiser and VU meter.</string>
</dict>
</plist>
PLIST
}

# Assemble a signed .app bundle at $1 around the binary at $2.
make_bundle() {
  local dest="$1" bin="$2"
  rm -rf "$dest"
  mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
  write_plist "$dest"
  cp "$bin" "$dest/Contents/MacOS/$NAME"
  chmod +x "$dest/Contents/MacOS/$NAME"
  if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$dest/Contents/Resources/AppIcon.icns"
  else
    echo "WARNING: AppIcon.icns not found next to build.sh - app will use the generic icon."
  fi
  codesign --force --sign - "$dest"   # ad-hoc: lets macOS remember camera/mic grants
  touch "$dest"                        # nudge Finder/Dock to refresh the icon
}

compile() {  # compile $2 = target triple -> binary at $1
  swiftc -O -target "$2" main.swift -o "$1" \
    -framework Cocoa -framework AVFoundation -framework Accelerate
}

ARM="$(mktemp -t rm-arm64)"
X86="$(mktemp -t rm-x86_64)"
UNI="$(mktemp -t rm-universal)"
trap 'rm -f "$ARM" "$X86" "$UNI"' EXIT

# Refresh the local universal app, unless a running copy holds its binary (common
# when RecordMonitor is open on the SMB host you build onto — you can't overwrite a
# running executable). In that case, leave the running bundle intact and carry on.
install_local() {
  if rm -f "$APP/Contents/MacOS/$NAME" 2>/dev/null; then   # frees only if not in use
    rm -rf "$APP"
    make_bundle "$APP" "$UNI"
    echo "Built $APP (universal — runs on both architectures)"
  else
    write_plist "$APP"                                      # repair bundle, don't touch the live binary
    mkdir -p "$APP/Contents/Resources"
    [ -f AppIcon.icns ] && cp -f AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
    echo "NOTE: $APP is currently running (likely on the SMB host), so its binary"
    echo "      wasn't replaced. The dist/ zips below are built and ready. Quit"
    echo "      RecordMonitor and re-run ./build.sh to refresh the local app."
  fi
}

echo "Compiling Apple Silicon (arm64)…"
compile "$ARM" arm64-apple-macos14.0
echo "Compiling Intel (x86_64)…"
compile "$X86" x86_64-apple-macos14.0

# Distribution first (never touches the local app): one thin, arch-specific .app per
# zip. The .app inside each zip is always named RecordMonitor.app; the *zip filename*
# carries the architecture so the in-app updater can pick the right one. Use ditto so
# app bundles zip cleanly (preserves symlinks/permissions).
rm -rf "$DIST"; mkdir -p "$DIST/as" "$DIST/intel"
make_bundle "$DIST/as/$APP"    "$ARM"
make_bundle "$DIST/intel/$APP" "$X86"
( cd "$DIST/as"    && ditto -c -k --sequesterRsrc --keepParent "$APP" "../$NAME-AppleSilicon.zip" )
( cd "$DIST/intel" && ditto -c -k --sequesterRsrc --keepParent "$APP" "../$NAME-Intel.zip" )
rm -rf "$DIST/as" "$DIST/intel"

# Local convenience app (universal), best-effort.
lipo -create "$ARM" "$X86" -output "$UNI"
install_local

echo "Built distribution zips in $DIST/:"
echo "  $NAME-AppleSilicon.zip   (Apple Silicon — M1/M2/M3/M4)"
echo "  $NAME-Intel.zip          (Intel)"
echo
echo "Run locally:  open $APP"
echo "Release:      upload both $DIST/*.zip as assets on a GitHub release"
