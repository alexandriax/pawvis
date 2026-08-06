#!/usr/bin/env bash
#
# scripts/generate_icon.sh
#
# Generates Pawvis's app icon artwork, menu bar glyph, and README banner via
# the OpenAI Images API, then builds Resources/AppIcon.icns from the master
# icon PNG.
#
# Outputs:
#   Resources/icon_1024.png     - master 1024x1024 app icon artwork
#   Resources/AppIcon.icns      - macOS .icns bundle built from icon_1024.png
#   Resources/menubar-claw.png  - 128x128 black-on-transparent menu bar template glyph
#   docs/banner.png             - wide README hero banner (1536x1024)
#
# Usage:
#   ./scripts/generate_icon.sh                 # generate anything missing, then (re)build the .icns
#   ./scripts/generate_icon.sh --force-icon     # regenerate icon_1024.png even if it already exists
#   ./scripts/generate_icon.sh --force-banner   # regenerate docs/banner.png even if it already exists
#   ./scripts/generate_icon.sh --force-menubar  # regenerate menubar-claw.png even if it already exists
#   ./scripts/generate_icon.sh --force          # regenerate all three images
#   ./scripts/generate_icon.sh --icns-only      # skip all API calls; just rebuild the .icns from
#                                                # the icon_1024.png that is already on disk
#
# To tweak a prompt without editing this file (e.g. after visually reviewing
# a generated image and deciding it needs another pass), override via env:
#
#   ICON_PROMPT="..."    ./scripts/generate_icon.sh --force-icon
#   BANNER_PROMPT="..."  ./scripts/generate_icon.sh --force-banner
#   MENUBAR_PROMPT="..." ./scripts/generate_icon.sh --force-menubar
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
MENUBAR_PNG="$RESOURCES_DIR/menubar-claw.png"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

FORCE_ICON=0
FORCE_BANNER=0
FORCE_MENUBAR=0
ICNS_ONLY=0

usage() {
  cat <<'USAGE'
Usage: generate_icon.sh [--force | --force-icon | --force-banner | --force-menubar | --icns-only | --help]

  --force          Regenerate icon_1024.png, banner.png, and menubar-claw.png even if present.
  --force-icon     Regenerate Resources/icon_1024.png even if present.
  --force-banner   Regenerate docs/banner.png even if present.
  --force-menubar  Regenerate Resources/menubar-claw.png even if present.
  --icns-only      Skip all image generation; just rebuild Resources/AppIcon.icns
                    from the existing Resources/icon_1024.png.
  --help           Show this help.

Prompt overrides (no need to edit this file):
  ICON_PROMPT="..."    ./scripts/generate_icon.sh --force-icon
  BANNER_PROMPT="..."  ./scripts/generate_icon.sh --force-banner
  MENUBAR_PROMPT="..." ./scripts/generate_icon.sh --force-menubar
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --force) FORCE_ICON=1; FORCE_BANNER=1; FORCE_MENUBAR=1 ;;
    --force-icon) FORCE_ICON=1 ;;
    --force-banner) FORCE_BANNER=1 ;;
    --force-menubar) FORCE_MENUBAR=1 ;;
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

DEFAULT_ICON_PROMPT="A macOS application icon: full-bleed square artwork that completely fills the entire 1024x1024 canvas edge to edge, corner to corner. The background itself is the design and must reach every edge of the frame; do NOT draw a rounded-square badge or rounded shape floating on a white or transparent backdrop, since macOS already applies the rounded-corner mask on top of this square afterward. Fill the whole square with a smooth gradient background transitioning from sky blue #0EA5E9 at the top to violet purple #8B5CF6 at the bottom. Composition: a furry warm tan/cream SLOTH forearm enters the frame from the top edge of the canvas, cropped by the top edge as if reaching down from off-camera, and ends in a small rounded wrist/paw near the top of the canvas. From that paw, exactly THREE claws hang down and dominate the rest of the composition: the claws are the single most important part of this image and must fill at least 60 percent of the canvas height. Each claw is EXTREMELY LONG, much longer than the paw itself, and stays thin and NARROW along its entire length, with NO wide or triangular base. Each claw must look exactly like a capital letter J, a shepherd's crook, or a coat hook: a long gently-curving section that sweeps down and outward, ending in an unmistakable tight hooked curl at the bottom, so the very tip points back up and inward, forming a clear open loop you could hang something on. All THREE claws must show this same full hook curl at their tips, evenly spaced and fanned out so each hooked curl is fully visible and separate from the others, not overlapping or bunched together. Absolutely NOT short stubby triangular nails, NOT cat-claw or bear-claw shapes, NOT cone-shaped spikes, NOT claws that merely taper to a point without curling back. FLAT DESIGN RENDERING STYLE IS MANDATORY: flat matte solid color fills only, like a simple 2D vector icon or sticker; NO 3D rendering, NO glossy plastic or balloon-like highlights, NO glassy tube shading, NO inflated/rubbery look. Use just one or two flat shade steps per claw (a base cream/tan tone plus maybe one slightly darker flat shadow stripe along one edge) and a single soft drop shadow beneath the whole shape for depth; keep edges crisp and flat like a modern app icon, not a rendered 3D object. Blunt, softly-rounded claw tips, never needle-sharp. A small simple flat white mouse-cursor arrow shape sits nestled directly inside the open curl of the middle claw's hook, its top edge physically touching and tucked into the inside of that curve, as though the hook is cradling it directly, the way a sloth hangs suspended from a tree branch; there must be NO thread, string, wire, or line of any kind drawn connecting the cursor to the claw. Clean bold shapes, contemporary professional flat-vector app-icon aesthetic, balanced negative space. Use only this blue/purple palette (sky blue #0EA5E9, violet #8B5CF6, light tints #7DD3FC / #C4B5FD) plus the tan/cream fur and claw colors; no green and no orange anywhere in the image. Absolutely no text, no letters, no words, no numbers, no watermark, no signature anywhere in the image."

DEFAULT_BANNER_PROMPT="A wide hero banner image for a macOS menu bar app called Pawvis, horizontal composition on a 1536x1024 canvas, background filled edge to edge with a smooth gradient from sky blue #0EA5E9 to violet purple #8B5CF6. On the left third of the composition: a furry warm tan/cream SLOTH forearm entering from the top edge of the canvas and ending in a small rounded wrist/paw, from which exactly THREE claws hang down and dominate that side of the image: the claws are the single most important visual element. Each claw is EXTREMELY LONG, much longer than the paw itself, and stays thin and NARROW along its entire length, with NO wide or triangular base. Each claw must look exactly like a capital letter J, a shepherd's crook, or a coat hook: a long gently-curving section that sweeps down, ending in an unmistakable tight hooked curl at the bottom so the tip points back up and inward, forming a clear open loop. All THREE claws must show this same full hook curl at their tips, evenly spaced and fanned out so each hooked curl is fully visible, not overlapping or bunched together. Absolutely NOT short stubby triangular nails, NOT cat-claw or bear-claw shapes, NOT cone-shaped spikes, NOT claws that merely taper to a point without curling back. FLAT DESIGN RENDERING STYLE IS MANDATORY: flat matte solid color fills only, like a simple 2D vector icon or sticker; NO 3D rendering, NO glossy plastic or balloon-like highlights, NO glassy tube shading. Use just one or two flat shade steps per claw and a single soft drop shadow for depth. Blunt, softly-rounded claw tips, never needle-sharp. A small simple flat white mouse-cursor arrow shape sits nestled directly inside the open curl of the middle claw's hook, its top edge physically touching and tucked into the inside of that curve, the way a sloth hangs suspended from a branch; there must be NO thread, string, wire, ring, or line of any kind drawn connecting the cursor to the claw. To the right of the paw artwork: large, clean, modern bold sans-serif wordmark text reading exactly \"Pawvis\" in light cream or white lettering, simple and legible, correctly spelled P-A-W-V-I-S, vertically centered, with no other text, taglines, or extra characters anywhere in the image. Clean bold shapes, contemporary professional flat-vector software-branding composition, generous margins. Use only this blue/purple palette (sky blue #0EA5E9, violet #8B5CF6, light tints #7DD3FC / #C4B5FD) plus the tan/cream fur and claw colors; no green and no orange anywhere in the image."

DEFAULT_MENUBAR_PROMPT="A minimalist monochrome menu bar icon glyph for macOS, flat 2D vector silhouette. Render ONLY a solid, 100 percent opaque BLACK silhouette shape against a fully transparent background: no gradient, no colors, no outlines, no shading, no texture, no drop shadow, nothing but solid black pixels and transparent pixels. Subject: exactly THREE long, narrow claw-hook shapes fused at a small rounded knuckle/base at the top, fanning out and hanging down. Each claw must look like a capital letter J, a shepherd's crook, or a coat hook: it sweeps down and outward, then curls back on itself into a tight, unmistakable hooked curl at the bottom so the tip points back up and inward, forming a clear open loop, not just a curved taper to a point. All three claws show this same tight hook curl. No fur texture, no toes, no pads, a simplified bold iconographic silhouette, not a realistic paw. NOT short triangular nails, NOT cat-claw or cone shapes, NOT claws that merely taper to a point without curling back. Keep strokes thick and bold, not spindly hairlines, so the three hooked claws stay clean and instantly recognizable even when the whole image is shrunk down to 16-22 pixels tall, like a macOS SF Symbol or toolbar icon. Simple, crisp, high-contrast vector edges. No text, no letters, no numbers, no border, no circle or square backdrop shape: only the black claw silhouette floating on transparency."

ICON_PROMPT="${ICON_PROMPT:-$DEFAULT_ICON_PROMPT}"
BANNER_PROMPT="${BANNER_PROMPT:-$DEFAULT_BANNER_PROMPT}"
MENUBAR_PROMPT="${MENUBAR_PROMPT:-$DEFAULT_MENUBAR_PROMPT}"

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
  local model="$1" prompt="$2" size="$3" out_png="$4" background="${5:-}"

  local body_file="$SCRATCH_DIR/body_${model}.json"
  local resp_file="$SCRATCH_DIR/resp_${model}.json"

  python3 - "$model" "$prompt" "$size" "$body_file" "$background" <<'PYEOF'
import json, sys
model, prompt, size, body_path, background = sys.argv[1:6]
payload = {
    "model": model,
    "prompt": prompt,
    "n": 1,
    "size": size,
    "quality": "high",
    "output_format": "png",
}
if background:
    # e.g. "transparent" for the menu bar glyph; gpt-image-1.5 (and the rest
    # of the gpt-image family) accept this alongside output_format=png.
    payload["background"] = background
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
  local prompt="$1" size="$2" out_png="$3" label="$4" background="${5:-}"
  echo "==> Generating $label ($size) -> $out_png" >&2
  local model
  for model in "${MODELS[@]}"; do
    if try_one_model "$model" "$prompt" "$size" "$out_png" "$background"; then
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
# Step 3: menu bar template glyph (solid black claw-hook silhouette on a
# transparent background, downscaled to the 128x128 PNG macOS wants for a
# template menu bar image).
# ---------------------------------------------------------------------------

MENUBAR_MODEL_USED="(skipped -- already present)"
if [[ "$ICNS_ONLY" -eq 1 ]]; then
  MENUBAR_MODEL_USED="(skipped -- --icns-only)"
  echo "==> --icns-only: skipping menu bar glyph generation." >&2
elif [[ "$FORCE_MENUBAR" -eq 0 ]] && is_valid_png "$MENUBAR_PNG"; then
  echo "==> $MENUBAR_PNG already exists -- skipping generation (use --force-menubar to redo)." >&2
else
  MENUBAR_SOURCE_PNG="$SCRATCH_DIR/menubar_source_1024.png"
  generate_image "$MENUBAR_PROMPT" "1024x1024" "$MENUBAR_SOURCE_PNG" "menu bar template glyph" "transparent"
  MENUBAR_MODEL_USED="$LAST_MODEL_USED"

  if ! is_valid_png "$MENUBAR_SOURCE_PNG"; then
    echo "ERROR: menu bar glyph generation produced no usable PNG." >&2
    exit 1
  fi

  echo "==> Downscaling menu bar glyph to 128x128 -> $MENUBAR_PNG" >&2
  sips -z 128 128 "$MENUBAR_SOURCE_PNG" --out "$MENUBAR_PNG" >/dev/null

  ALPHA_CHECK="$(sips -g hasAlpha "$MENUBAR_PNG" 2>/dev/null | awk -F': ' '/hasAlpha/ {print $2}')"
  if [[ "$ALPHA_CHECK" == "yes" ]]; then
    echo "==> $MENUBAR_PNG has a real alpha channel (hasAlpha: yes)." >&2
  else
    echo "WARNING: $MENUBAR_PNG hasAlpha=${ALPHA_CHECK:-unknown} -- macOS renders template" >&2
    echo "         menu bar images from alpha only, so this glyph will likely render as a" >&2
    echo "         solid block instead of the claw silhouette. Inspect it and consider" >&2
    echo "         re-running with --force-menubar." >&2
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: build Resources/AppIcon.icns from icon_1024.png via a .iconset
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
echo "  $MENUBAR_PNG  ($MENUBAR_MODEL_USED)" >&2
echo "====================================================================" >&2
