#!/bin/bash
# Stores the signing + notarization credentials CI needs, as GitHub secrets.
#
# RUN THIS YOURSELF, interactively — it handles private keys and passwords, so
# nothing here should be automated or pasted into a chat:
#
#     ./scripts/setup_signing.sh
#
# What it needs first:
#   1. A "Developer ID Application" certificate in your login keychain
#      (already present if `security find-identity -v` lists one).
#   2. Notarization credentials — EITHER of:
#      a. An app-specific password (simplest, instant): sign in at
#         https://account.apple.com → Sign-In and Security → App-Specific
#         Passwords → generate one for "Pawvis notarization".
#      b. An App Store Connect API key:
#         https://appstoreconnect.apple.com/access/integrations/api
#         → Team Keys → "+" → Access: Developer. Downloads the .p8 once.
#         (Requires requesting API access, which Apple reviews.)
#
# Secrets it sets: MACOS_CERT_P12, MACOS_CERT_PASSWORD, plus either
# NOTARY_APPLE_ID/NOTARY_PASSWORD/NOTARY_TEAM_ID or
# NOTARY_KEY_P8/NOTARY_KEY_ID/NOTARY_ISSUER_ID.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="${PAWVIS_REPO:-alexandriax/pawvis}"

command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first" >&2; exit 1; }

echo "Repository: $REPO"
echo

# ---------------------------------------------------------------- certificate
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
if [[ -z "$IDENTITY" ]]; then
    echo "No 'Developer ID Application' certificate found in your keychain." >&2
    echo "Create one at https://developer.apple.com/account/resources/certificates" >&2
    exit 1
fi
echo "Found certificate: $IDENTITY"

TMP_P12=$(mktemp -t pawvis-cert).p12
cleanup() { rm -f "$TMP_P12"; }
trap cleanup EXIT

echo
echo "Exporting the certificate and its private key."
echo "Choose an export password — you'll be asked for it twice by macOS, and"
echo "it gets stored as the MACOS_CERT_PASSWORD secret."
read -rsp "Export password: " P12_PASSWORD; echo
[[ -n "$P12_PASSWORD" ]] || { echo "Password cannot be empty" >&2; exit 1; }

# -P passes the password to the export; macOS may still prompt to allow access
# to the private key — approve it.
security export -t identities -f pkcs12 -P "$P12_PASSWORD" -o "$TMP_P12"

base64 -i "$TMP_P12" | gh secret set MACOS_CERT_P12 --repo "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set MACOS_CERT_PASSWORD --repo "$REPO"
unset P12_PASSWORD
echo "✓ MACOS_CERT_P12, MACOS_CERT_PASSWORD set"

# -------------------------------------------------------------- notarization
# The team ID is the parenthesised code in the certificate name.
TEAM_ID=$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$IDENTITY")

echo
echo "Notarization removes the right-click → Open prompt on a fresh download."
echo "  1) App-specific password  (simplest — account.apple.com, instant)"
echo "  2) App Store Connect API key (.p8)"
echo "  3) Skip for now"
read -rp "Choose [1/2/3]: " NOTARY_CHOICE

case "${NOTARY_CHOICE:-3}" in
  1)
    read -rp "Apple ID email: " APPLE_ID
    read -rsp "App-specific password (xxxx-xxxx-xxxx-xxxx): " ASP; echo
    read -rp "Team ID [$TEAM_ID]: " ENTERED_TEAM
    TEAM_ID="${ENTERED_TEAM:-$TEAM_ID}"
    [[ -n "$APPLE_ID" && -n "$ASP" && -n "$TEAM_ID" ]] || {
        echo "All three are required" >&2; exit 1; }

    printf '%s' "$APPLE_ID" | gh secret set NOTARY_APPLE_ID --repo "$REPO"
    printf '%s' "$ASP"      | gh secret set NOTARY_PASSWORD --repo "$REPO"
    printf '%s' "$TEAM_ID"  | gh secret set NOTARY_TEAM_ID  --repo "$REPO"
    unset ASP
    echo "✓ NOTARY_APPLE_ID, NOTARY_PASSWORD, NOTARY_TEAM_ID set"
    ;;
  2)
    read -rp "Path to the .p8 key: " P8_PATH
    P8_PATH="${P8_PATH/#\~/$HOME}"
    [[ -f "$P8_PATH" ]] || { echo "No such file: $P8_PATH" >&2; exit 1; }
    read -rp "Key ID (10 characters, from the key's filename): " KEY_ID
    read -rp "Issuer ID (UUID shown above the key list): " ISSUER_ID

    base64 -i "$P8_PATH" | gh secret set NOTARY_KEY_P8 --repo "$REPO"
    printf '%s' "$KEY_ID"    | gh secret set NOTARY_KEY_ID    --repo "$REPO"
    printf '%s' "$ISSUER_ID" | gh secret set NOTARY_ISSUER_ID --repo "$REPO"
    echo "✓ NOTARY_KEY_P8, NOTARY_KEY_ID, NOTARY_ISSUER_ID set"
    ;;
  *)
    echo "Skipped notarization — releases will be signed but not notarized,"
    echo "so a fresh download still needs right-click → Open. (The signature"
    echo "alone is what keeps Accessibility working across updates.)"
    ;;
esac

echo
echo "Done. Secrets on $REPO:"
gh secret list --repo "$REPO"
echo
echo "Next release (git tag vX.Y.Z && git push origin vX.Y.Z) will be signed"
echo "with your Developer ID, so the Accessibility grant survives updates."
