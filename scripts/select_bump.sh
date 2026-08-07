#!/usr/bin/env bash
# Read a pull request's labels and decide how the version moves.
#
#   LABELS='["minor","documentation"]' ./scripts/select_bump.sh
#   minor
#
# Exactly one of `major`, `minor` or `patch` has to be on the PR, or
# `no-release` to merge without cutting anything. Anything else is an error,
# because the alternative is guessing — and a wrong guess here ships a version
# number that can never be taken back.
#
# Prints the decision (major/minor/patch/none) on stdout and appends `bump=` to
# $GITHUB_OUTPUT. Used by the PR gate and by the release workflow, so the rule
# is written down once.
set -euo pipefail

HELP="Label the pull request with exactly one of major, minor, patch to say how
the version should move, or no-release to merge without cutting a release."

raw="${1:-${LABELS:-}}"

# Actions hands us a JSON array; a plain comma-separated list also works, which
# is what makes this runnable by hand.
if [ "${raw#[}" != "$raw" ]; then
    names="$(printf '%s' "$raw" | jq -r '.[] | if type == "object" then .name else . end')"
else
    names="$(printf '%s' "$raw" | tr ',' '\n')"
fi

declare -a hits=()
skip=false
while IFS= read -r name; do
    name="${name#"${name%%[![:space:]]*}"}"          # trim leading space
    name="${name%"${name##*[![:space:]]}"}"          # trim trailing space
    name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    case "$name" in
        major | minor | patch) hits+=("$name") ;;
        no-release) skip=true ;;
    esac
done <<< "$names"

if [ "$skip" = true ]; then
    if [ "${#hits[@]}" -gt 0 ]; then
        echo "error: no-release cannot be combined with ${hits[*]}." >&2
        echo "$HELP" >&2
        exit 1
    fi
    bump=none
elif [ "${#hits[@]}" -eq 0 ]; then
    echo "error: no release label found." >&2
    echo "$HELP" >&2
    exit 1
elif [ "${#hits[@]}" -gt 1 ]; then
    echo "error: ${hits[*]} are all set — pick one." >&2
    echo "$HELP" >&2
    exit 1
else
    bump="${hits[0]}"
fi

echo "$bump"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "bump=$bump" >> "$GITHUB_OUTPUT"
fi
