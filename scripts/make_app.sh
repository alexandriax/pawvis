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
# The About pane's portrait: the photoreal paw the README leads with. Copied
# from the repo root rather than duplicated into Resources/ so the two can't
# drift — Resources/ holds art derived from claw.png, this isn't.
cp icon.png "$APP/Contents/Resources/paw-photo.png"
# `cmd && cp` would abort the script under `set -e` whenever the test is
# false, so guard these with explicit ifs.
if [[ -f Resources/menubar-claw.png ]]; then
    cp Resources/menubar-claw.png "$APP/Contents/Resources/"
fi
if [[ -f Resources/claw-closed.png ]]; then
    cp Resources/claw-closed.png "$APP/Contents/Resources/"
fi
# The Gesture Guide's posed hands, taken from the site's own copies so the
# guide and the gestures grid can never show different poses. Flattened into
# Resources/ with a prefix because the bundle has no subfolders; the app
# tints them, so the site's colors inside them don't matter.
for glyph in docs/assets/gestures/*.svg; do
    [[ -f "$glyph" ]] || continue
    cp "$glyph" "$APP/Contents/Resources/gesture-$(basename "$glyph")"
done
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
    <!-- Continuity Camera opt-in (macOS 14+). Without it macOS still lists
         an iPhone, but typed as a plain external (or built-in) camera, so
         Pawvis could not tell the phone from the Mac's own camera — and
         Automatic's "built-in first" rule became a coin toss. AGENTS.md →
         Cameras has the measurements. -->
    <key>NSCameraUseContinuityCameraDeviceType</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Pawvis uses your microphone for voice control. Speech recognition runs entirely on this Mac — audio never leaves it.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Pawvis uses on-device speech recognition to understand your voice commands and dictation.</string>
</dict>
</plist>
PLIST

# Signing identity, best first. This matters more than it looks: macOS ties the
# Accessibility grant to the app's *designated requirement*. A real identity
# yields an identity-based requirement that survives rebuilds and updates; an
# ad-hoc signature yields a per-binary cdhash, so every new build looks like a
# different app and clicking silently stops working (while System Settings
# still shows Pawvis as enabled).
#
# Developer ID is preferred over Apple Development so that locally built and
# CI-released copies share one requirement — grant Accessibility once, and it
# holds across updates.
#
# `|| true`: under `set -euo pipefail`, grep matching nothing (every CI machine
# without secrets) would otherwise abort the build.
find_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep -o "\"$1: [^\"]*\"" | head -1 | tr -d '"' || true
}

IDENTITY=$(find_identity "Developer ID Application")
SIGN_KIND="Developer ID"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY=$(find_identity "Apple Development")
    SIGN_KIND="Apple Development"
fi

if [[ -n "$IDENTITY" ]]; then
    SIGN_ARGS=(--force --sign "$IDENTITY" --timestamp)
    if [[ "$SIGN_KIND" == "Developer ID" ]]; then
        # Notarization requires the Hardened Runtime; the entitlements give the
        # camera and microphone back under it.
        SIGN_ARGS+=(--options runtime --entitlements Resources/Pawvis.entitlements)
    fi
    codesign "${SIGN_ARGS[@]}" "$APP"
    echo "Signed with '$IDENTITY' — stable identity, permissions survive rebuilds"
else
    codesign --force --sign - "$APP"
    cat >&2 <<'WARN'
WARNING: ad-hoc signed (no Developer ID or Apple Development identity found).
Every rebuild changes the signature, so macOS silently drops the Accessibility
grant: remove and re-add Pawvis in System Settings → Privacy & Security →
Accessibility, or clicks will do nothing.
WARN
fi

echo "Built $APP"
