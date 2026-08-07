#!/bin/bash
# Assembles build/Pawvis.app from the release binary + resources.
# Ad-hoc signed: fine for local use; macOS re-prompts for permissions when the
# signature changes (i.e., after rebuilds).
set -euo pipefail

cd "$(dirname "$0")/.."

# CI stamps the release tag here (`VERSION=1.2.3 ./scripts/make_app.sh`);
# local builds get a placeholder so the About pane never claims a real version.
VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
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
# `cmd && cp` would abort the script under `set -e` whenever the test is
# false, so guard these with explicit ifs.
if [[ -f Resources/menubar-claw.png ]]; then
    cp Resources/menubar-claw.png "$APP/Contents/Resources/"
fi
if [[ -f Resources/claw-closed.png ]]; then
    cp Resources/claw-closed.png "$APP/Contents/Resources/"
fi
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
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
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

# Prefer a real signing identity: ad-hoc signatures change every build, which
# silently invalidates the Accessibility grant (while System Settings still
# shows it enabled) — the classic "cursor moves but nothing clicks" trap.
# `|| true`: with `set -euo pipefail`, grep finding no identity (every CI
# machine) would otherwise abort the whole build.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with '$IDENTITY' — stable identity, permissions survive rebuilds"
else
    codesign --force --sign - "$APP"
    cat >&2 <<'WARN'
WARNING: ad-hoc signed (no "Apple Development" identity found in the keychain).
After EVERY rebuild you must remove and re-add Pawvis in
System Settings → Privacy & Security → Accessibility, or clicks silently fail.
(Sign into Xcode with an Apple ID to get a free stable identity.)
WARN
fi

echo "Built $APP"
