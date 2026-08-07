#!/usr/bin/env bash
# Print the version the next release should carry.
#
#   ./scripts/next_version.sh minor
#   0.2.0
#
# There is no version file to bump: the newest `v*` tag *is* the current
# version, and `make_app.sh` stamps whatever VERSION it is handed into
# Info.plist. So this only has to read the tag list and do the arithmetic —
# which means it needs a full clone, since a shallow one fetches no tags.
#
# Prints the version on stdout and appends `version=`/`tag=` to $GITHUB_OUTPUT.
set -euo pipefail

kind="${1:-}"
case "$kind" in
    major | minor | patch) ;;
    *)
        echo "usage: $0 {major|minor|patch}" >&2
        exit 1
        ;;
esac

latest="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -1)"
current="${latest#v}"
# No tags yet: the first release off a `minor` label is 0.1.0.
[ -n "$current" ] || current="0.0.0"

if ! [[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "error: newest tag '$latest' is not vMAJOR.MINOR.PATCH" >&2
    exit 1
fi
# 10# so a zero-padded component is not read as octal.
major="$((10#${BASH_REMATCH[1]}))"
minor="$((10#${BASH_REMATCH[2]}))"
patch="$((10#${BASH_REMATCH[3]}))"

case "$kind" in
    major) major=$((major + 1)) minor=0 patch=0 ;;
    minor) minor=$((minor + 1)) patch=0 ;;
    patch) patch=$((patch + 1)) ;;
esac

version="$major.$minor.$patch"
echo "$version"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "version=$version"
        echo "tag=v$version"
    } >> "$GITHUB_OUTPUT"
fi
