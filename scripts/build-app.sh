#!/bin/bash
# Builds Murmur.app from the Swift package: compile, assemble the bundle, embed llama.framework, sign.
# Usage: scripts/build-app.sh [release|debug] [--install]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
INSTALL="${2:-}"
VERSION="1.0.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

BUILD_LOG="$(mktemp)"
if ! swift build -c "$CONFIG" --product Murmur > "$BUILD_LOG" 2>&1; then
  grep -E "error" "$BUILD_LOG" | head -40
  echo "BUILD FAILED"
  exit 1
fi
rm -f "$BUILD_LOG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP=".build/app/Murmur.app"
rm -rf "$APP" build/Murmur.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Murmur" "$APP/Contents/MacOS/Murmur"
cp -R Vendor/llama.xcframework/macos-arm64_x86_64/llama.framework "$APP/Contents/Frameworks/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.murmur.Murmur</string>
  <key>CFBundleName</key><string>Murmur</string>
  <key>CFBundleDisplayName</key><string>Murmur</string>
  <key>CFBundleExecutable</key><string>Murmur</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Murmur listens while you hold your dictation key so it can turn your speech into text. Audio never leaves your Mac.</string>
  <key>NSHumanReadableCopyright</key><string>Built with WhisperKit and llama.cpp.</string>
</dict>
</plist>
PLIST

# Prefer a real signing identity (stable, so macOS keeps permissions across rebuilds); fall back to ad-hoc.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -E 'Apple Development|Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)"
SIGN="${IDENTITY:--}"
codesign --force --sign "$SIGN" --timestamp=none "$APP/Contents/Frameworks/llama.framework" >/dev/null
codesign --force --sign "$SIGN" --timestamp=none --identifier app.murmur.Murmur "$APP" >/dev/null
codesign --verify --deep --strict "$APP" && echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "$INSTALL" = "--install" ]; then
  pkill -x Murmur 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Murmur.app
  cp -R "$APP" /Applications/Murmur.app
  echo "Installed to /Applications/Murmur.app"
fi
