#!/usr/bin/env bash
#
# scripts/generate_icon.sh
#
# Generates Pawvis's app icon artwork and README banner via the OpenAI Images
# API, then builds Resources/AppIcon.icns from the master icon PNG.
#
# Outputs:
#   Resources/icon_1024.png   - master 1024x1024 app icon artwork
#   Resources/AppIcon.icns    - macOS .icns bundle built from icon_1024.png
#   docs/banner.png           - wide README hero banner (1536x1024)
#
# Usage:
#   ./scripts/generate_icon.sh                 # generate anything missing, then (re)build the .icns
#   ./scripts/generate_icon.sh --force-icon     # regenerate icon_1024.png even if it already exists
#   ./scripts/generate_icon.sh --force-banner   # regenerate docs/banner.png even if it already exists
#   ./scripts/generate_icon.sh --force          # regenerate both images
#   ./scripts/generate_icon.sh --icns-only      # skip all API calls; just rebuild the .icns from
#                                                # the icon_1024.png that is already on disk
#
# To tweak a prompt without editing this file (e.g. after visually reviewing
# a generated image and deciding it needs another pass), override via env:
#
#   ICON_PROMPT="..."   ./scripts/generate_icon.sh --force-icon
#   BANNER_PROMPT="..." ./scripts/generate_icon.sh --force-banner
#
# Requirements: curl, python3 (stdlib json/base64 only), sips, iconutil, file.
# sips/iconutil are macOS-only, so this script only runs on macOS.
#
# Secrets handling:
#   - Reads OPENAI_API_KEY from "<repo root>/.env" (never printed, never
#     logged, never written to any file other than the .env it was read
#     from).
#   - The key is referenced only as "$OPENAI_API_KEY" when building the curl
#     Authorization header for the OpenAI API call.
#
# Idempotency:
#   - Re-running with no flags is safe: it skips image generation for any
#     output file that already exists and looks like a valid PNG, and always
#     rebuilds Resources/AppIcon.icns from whatever icon_1024.png is present
#     (that step is cheap, local, and makes no API calls).
#   - Use the --force* flags above to force a specific image to regenerate.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RESOURCES_DIR="$REPO_ROOT/Resources"
DOCS_DIR="$REPO_ROOT/docs"
ENV_FILE="$REPO_ROOT/.env"

ICON_PNG="$RESOURCES_DIR/icon_1024.png"
ICNS_OUT="$RESOURCES_DIR/AppIcon.icns"
BANNER_PNG="$DOCS_DIR/banner.png"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

FORCE_ICON=0
FORCE_BANNER=0
ICNS_ONLY=0

usage() {
  cat <<'USAGE'
Usage: generate_icon.sh [--force | --force-icon | --force-banner | --icns-only | --help]

  --force          Regenerate both icon_1024.png and banner.png even if present.
  --force-icon     Regenerate Resources/icon_1024.png even if present.
  --force-banner   Regenerate docs/banner.png even if present.
  --icns-only      Skip all image generation; just rebuild Resources/AppIcon.icns
                    from the existing Resources/icon_1024.png.
  --help           Show this help.

Prompt overrides (no need to edit this file):
  ICON_PROMPT="..."   ./scripts/generate_icon.sh --force-icon
  BANNER_PROMPT="..." ./scripts/generate_icon.sh --force-banner
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --force) FORCE_ICON=1; FORCE_BANNER=1 ;;
    --force-icon) FORCE_ICON=1 ;;
    --force-banner) FORCE_BANNER=1 ;;
    --icns-only) ICNS_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

for tool in curl python3 sips iconutil file; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool '$tool' not found on PATH." >&2
    exit 1
  fi
done

if [[ "$ICNS_ONLY" -ne 1 ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE not found. It must contain OPENAI_API_KEY=..." >&2
    exit 1
  fi

  # Load .env into the environment (and only the environment — never re-emit it).
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "ERROR: OPENAI_API_KEY is not set after sourcing $ENV_FILE." >&2
    exit 1
  fi
fi

mkdir -p "$RESOURCES_DIR" "$DOCS_DIR"

# ---------------------------------------------------------------------------
# Scratch space (temp working dir for API responses + the .iconset bundle).
# Lives outside the repo; only cleaned up automatically on success so a
# failure leaves debug artifacts behind.
# ---------------------------------------------------------------------------

SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pawvis-icon-build.XXXXXX")"

cleanup() {
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    rm -rf "$SCRATCH_DIR"
  else
    echo "NOTE: leaving scratch/debug files at $SCRATCH_DIR (exit code $exit_code)" >&2
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Prompts (overridable via env so a bad generation can be retried without
# editing this file — see usage() above).
# ---------------------------------------------------------------------------

DEFAULT_ICON_PROMPT="A macOS application icon: full-bleed square artwork that completely fills the entire 1024x1024 canvas edge to edge. The background itself is the design and must reach every edge of the frame — do NOT draw a rounded-square badge or rounded shape floating on a white or transparent backdrop, since macOS already applies the rounded-corner mask on top of this square afterward. Fill the whole square, corner to corner, with a smooth soft gradient background transitioning from teal to indigo. Centered in the composition: a friendly, modern, flat-design cat-like paw pad (a cute paw print shape with rounded toe beans), rendered in warm cream / off-white flat color with gentle minimal shading and a subtle soft drop shadow for depth. Integrated into the paw, a small, simple, minimal mouse-cursor arrow shape nestles into the paw pad, as if the paw is gently pressing or holding the cursor. Crisp vector flat-illustration style, clean bold shapes, contemporary professional app-icon aesthetic, centered composition, balanced negative space. Absolutely no text, no letters, no words, no numbers, no watermark, no signature anywhere in the image."

DEFAULT_BANNER_PROMPT="A wide hero banner image for a macOS menu bar app called Pawvis, horizontal composition on a 1536x1024 canvas, background filled edge to edge with a smooth soft gradient from teal to indigo. On the left side: a friendly, modern, flat-design cat-like paw pad icon with rounded toe beans in warm cream color, with a small simple mouse-cursor arrow nestled into the paw as if gently pressing it — crisp vector flat-illustration style with a subtle soft drop shadow, matching a polished macOS app-icon aesthetic. To the right of the paw icon: large, clean, modern sans-serif wordmark text reading exactly \"Pawvis\" in bold cream or white lettering, simple and legible, correctly spelled P-A-W-V-I-S, with no other text, taglines, or extra characters anywhere in the image. Minimal, professional software-branding banner, generous margins, balanced composition."

ICON_PROMPT="${ICON_PROMPT:-$DEFAULT_ICON_PROMPT}"
BANNER_PROMPT="${BANNER_PROMPT:-$DEFAULT_BANNER_PROMPT}"

# ---------------------------------------------------------------------------
# OpenAI Images API helpers
# ---------------------------------------------------------------------------

# Models to try, in order. gpt-image-1.5 first; fall back on any model-related
# error (missing model, unsupported params, etc.) to the next one.
MODELS=("gpt-image-1.5" "gpt-image-1-mini" "gpt-image-1" "gpt-image-2")

is_valid_png() {
  local path="$1"
  [[ -s "$path" ]] || return 1
  file --brief "$path" 2>/dev/null | grep -q "PNG image data"
}

# Attempt one generation call with a single model. Writes $4 (out_png) and
# returns 0 on success. Returns 1 on any recoverable failure so the caller
# can fall back to the next model. Exits the whole script (via `exit`, not
# `return`) on a 403 organization-verification error, since no fallback or
# retry can fix that.
try_one_model() {
  local model="$1" prompt="$2" size="$3" out_png="$4"

  local body_file="$SCRATCH_DIR/body_${model}.json"
  local resp_file="$SCRATCH_DIR/resp_${model}.json"

  python3 - "$model" "$prompt" "$size" "$body_file" <<'PYEOF'
import json, sys
model, prompt, size, body_path = sys.argv[1:5]
payload = {
    "model": model,
    "prompt": prompt,
    "n": 1,
    "size": size,
    "quality": "high",
    "output_format": "png",
}
with open(body_path, "w") as f:
    json.dump(payload, f)
PYEOF

  local attempt=1
  local max_attempts=3
  while [[ "$attempt" -le "$max_attempts" ]]; do
    echo "   [$model] attempt $attempt/$max_attempts -- POST /v1/images/generations (size=$size)..." >&2

    local http_code
    http_code=$(curl -sS --max-time 180 \
      -o "$resp_file" -w "%{http_code}" \
      https://api.openai.com/v1/images/generations \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      --data-binary @"$body_file") || http_code="000"

    case "$http_code" in
      200)
        if python3 - "$resp_file" "$out_png" <<'PYEOF'
import base64, json, sys
resp_path, out_path = sys.argv[1], sys.argv[2]
with open(resp_path) as f:
    data = json.load(f)
try:
    b64 = data["data"][0]["b64_json"]
except (KeyError, IndexError, TypeError):
    sys.exit(1)
raw = base64.b64decode(b64)
if raw[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit(1)
with open(out_path, "wb") as f:
    f.write(raw)
PYEOF
        then
          echo "   [$model] succeeded -> $out_png" >&2
          return 0
        fi
        echo "   [$model] HTTP 200 but response had no usable image; treating as failure. Response:" >&2
        cat "$resp_file" >&2
        return 1
        ;;
      429)
        echo "   [$model] HTTP 429 rate-limited. Waiting 30s before retry..." >&2
        sleep 30
        attempt=$((attempt + 1))
        ;;
      403)
        if grep -qi "organization" "$resp_file" 2>/dev/null && grep -qiE "verif" "$resp_file" 2>/dev/null; then
          echo "FATAL: HTTP 403 -- organization verification required. This cannot be fixed by" >&2
          echo "retrying or falling back to another model. Response body:" >&2
          cat "$resp_file" >&2
          exit 3
        fi
        echo "   [$model] HTTP 403 (not organization verification). Response body:" >&2
        cat "$resp_file" >&2
        return 1
        ;;
      000)
        echo "   [$model] curl/network error on attempt $attempt." >&2
        attempt=$((attempt + 1))
        ;;
      *)
        echo "   [$model] HTTP $http_code. Response body:" >&2
        cat "$resp_file" >&2
        return 1
        ;;
    esac
  done

  echo "   [$model] exhausted retries." >&2
  return 1
}

# Try every model in $MODELS, in order, until one succeeds. Sets
# LAST_MODEL_USED on success.
LAST_MODEL_USED=""
generate_image() {
  local prompt="$1" size="$2" out_png="$3" label="$4"
  echo "==> Generating $label ($size) -> $out_png" >&2
  local model
  for model in "${MODELS[@]}"; do
    if try_one_model "$model" "$prompt" "$size" "$out_png"; then
      LAST_MODEL_USED="$model"
      return 0
    fi
    echo "   -- falling back to next model --" >&2
  done
  echo "ERROR: every model in the fallback chain failed for $label." >&2
  return 1
}

# ---------------------------------------------------------------------------
# Step 1: master icon artwork
# ---------------------------------------------------------------------------

ICON_MODEL_USED="(skipped -- already present)"
if [[ "$ICNS_ONLY" -eq 1 ]]; then
  ICON_MODEL_USED="(skipped -- --icns-only)"
  echo "==> --icns-only: skipping icon generation." >&2
elif [[ "$FORCE_ICON" -eq 0 ]] && is_valid_png "$ICON_PNG"; then
  echo "==> $ICON_PNG already exists -- skipping generation (use --force-icon to redo)." >&2
else
  generate_image "$ICON_PROMPT" "1024x1024" "$ICON_PNG" "master app icon"
  ICON_MODEL_USED="$LAST_MODEL_USED"
fi

# ---------------------------------------------------------------------------
# Step 2: README banner
# ---------------------------------------------------------------------------

BANNER_MODEL_USED="(skipped -- already present)"
if [[ "$ICNS_ONLY" -eq 1 ]]; then
  BANNER_MODEL_USED="(skipped -- --icns-only)"
  echo "==> --icns-only: skipping banner generation." >&2
elif [[ "$FORCE_BANNER" -eq 0 ]] && is_valid_png "$BANNER_PNG"; then
  echo "==> $BANNER_PNG already exists -- skipping generation (use --force-banner to redo)." >&2
else
  generate_image "$BANNER_PROMPT" "1536x1024" "$BANNER_PNG" "README banner"
  BANNER_MODEL_USED="$LAST_MODEL_USED"
fi

# ---------------------------------------------------------------------------
# Step 3: build Resources/AppIcon.icns from icon_1024.png via a .iconset
# ---------------------------------------------------------------------------

if ! is_valid_png "$ICON_PNG"; then
  echo "ERROR: $ICON_PNG is missing or not a valid PNG; cannot build .icns." >&2
  exit 1
fi

ICONSET_DIR="$SCRATCH_DIR/Pawvis.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

echo "==> Building iconset in $ICONSET_DIR from $ICON_PNG" >&2

# name:pixel-size pairs per Apple's iconset naming convention.
ICONSET_SPECS=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

for spec in "${ICONSET_SPECS[@]}"; do
  name="${spec%%:*}"
  px="${spec##*:}"
  sips -z "$px" "$px" "$ICON_PNG" --out "$ICONSET_DIR/$name" >/dev/null
  echo "   generated $name (${px}x${px})" >&2
done

rm -f "$ICNS_OUT"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_OUT"

ICNS_BYTES=$(stat -f%z "$ICNS_OUT" 2>/dev/null || echo 0)
if [[ "$ICNS_BYTES" -lt 102400 ]]; then
  echo "WARNING: $ICNS_OUT is only $ICNS_BYTES bytes -- smaller than the ~100KB typically expected." >&2
else
  echo "==> Wrote $ICNS_OUT ($ICNS_BYTES bytes)" >&2
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "" >&2
echo "==================== generate_icon.sh summary ====================" >&2
echo "  $ICON_PNG  ($ICON_MODEL_USED)" >&2
echo "  $ICNS_OUT  ($ICNS_BYTES bytes)" >&2
echo "  $BANNER_PNG  ($BANNER_MODEL_USED)" >&2
echo "====================================================================" >&2
