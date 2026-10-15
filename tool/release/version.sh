#!/usr/bin/env bash
# Checks a release tag and prints what the builds are stamped with, as
# GitHub output lines: `name=1.2.3` and `build=<commit count>`.
# usage: version.sh <tag>
set -euo pipefail
fail() { echo "::error::$1" >&2; exit 1; }

tag="$1"

# Better to stop here than after three builds and a notarization.
for key in appimage.pub sparkle.pub flatpak.asc; do
  test -s "tool/release/keys/$key" || fail "tool/release/keys/$key is missing or empty"
done

git fetch -q origin main
commit="$(git rev-parse "$tag^{commit}")"
git merge-base --is-ancestor "$commit" origin/main || fail "the tag is not on main"
name="${tag#v}"
[[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "tags look like v1.2.3"

echo "name=$name"
# Every updater compares this, so it only ever goes up.
echo "build=$(git rev-list --count "$commit")"
