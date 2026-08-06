#!/bin/bash
# Assembles build/Pawvis.app from the release binary + resources.
# Ad-hoc signed: fine for local use; macOS re-prompts for permissions when the
# signature changes (i.e., after rebuilds).
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="1.0.0"
APP="build/Pawvis.app"
BIN=".build/release/Pawvis"

if [[ ! -x "$BIN" ]]; then
    echo "Release binary missing — run 'swift build -c release' first" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Pawvis"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/icon_1024.png "$APP/Contents/Resources/icon_1024.png"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleName</key><string>Pawvis</string>
    <key>CFBundleDisplayName</key><string>Pawvis</string>
    <key>CFBundleIdentifier</key><string>com.pawvis.Pawvis</string>
    <key>CFBundleExecutable</key><string>Pawvis</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSCameraUsageDescription</key>
    <string>Pawvis uses your camera to track hand gestures. Frames are processed entirely on this Mac and never leave it.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Pawvis uses your microphone for voice dictation. With the Apple engine, audio never leaves this Mac; with the OpenAI engine, audio is streamed to OpenAI only while dictation is armed.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Pawvis uses on-device speech recognition to turn your voice into typed text.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

echo "Built $APP"
