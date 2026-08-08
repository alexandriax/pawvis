#!/bin/bash
# Renders docs/banner.png — the Open Graph / Twitter card — from
# scripts/banner.html, so the share image and the splash page stay one design.
#
# Same idea as `make icon`: the art is committed, but it is *derived*, and
# re-running this on an unchanged banner.html reproduces it. The page pulls the
# site's own fonts and claw art out of docs/assets, so a splash restyle is a
# one-line edit here rather than a trip through an image generator.
#
# 1200x630 is the Open Graph standard ratio; rendering at 2x and resampling
# down keeps the type crisp on retina previews.
set -euo pipefail

cd "$(dirname "$0")/.."

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [[ ! -x "$CHROME" ]]; then
    echo "Chrome not found at '$CHROME' — set CHROME=/path/to/chrome" >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --allow-file-access-from-files: the page loads the woff2 faces over file://,
# and without it Chrome treats each one as a cross-origin font and silently
# falls back to the system sans, which changes the whole render.
"$CHROME" --headless --disable-gpu --hide-scrollbars \
    --allow-file-access-from-files \
    --screenshot="$TMP/banner@2x.png" \
    --window-size=1200,630 --force-device-scale-factor=2 \
    "file://$PWD/scripts/banner.html" >/dev/null 2>&1

sips --resampleHeightWidth 630 1200 "$TMP/banner@2x.png" --out docs/banner.png >/dev/null

echo "Wrote docs/banner.png (1200x630)"
