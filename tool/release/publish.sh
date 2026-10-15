#!/usr/bin/env bash
# Publishes a release from the jobs' artifacts: lays out the feeds, makes
# the GitHub Release public, then points get.loaf.moe at it. Needs GH_TOKEN
# and GITHUB_REPOSITORY.
# usage: publish.sh <tag> <artifacts dir>
set -euo pipefail

tag="$1"; artifacts="$2"
version="${tag#v}"
dist="$(mktemp -d)"
pages="$(mktemp -d)"

# The feeds first, so a bad layout fails while nothing points at it yet.
tar -xf "$artifacts/flatpak/repo.tar" -C "$dist"
cp "$artifacts/macos/appcast.xml" "$dist/"
# One feed: the Linux job's, with Windows' entry merged in.
jq -e -s '.[0] * .[1]' "$artifacts/linux/latest.json" \
  "$artifacts/windows/windows.json" > "$dist/latest.json"
jq -e '.appimage and .windows' "$dist/latest.json" >/dev/null
tool/release/pages.sh "$dist" "$pages"

gh release view "$tag" >/dev/null 2>&1 \
  || gh release create "$tag" --draft \
       --title "Loaf Chat $version" --generate-notes
gh release upload "$tag" --clobber \
  "$artifacts"/macos/*.dmg "$artifacts"/linux/*.AppImage \
  "$artifacts"/windows/*-Setup.exe "$artifacts"/windows/*.zip
# Public before any feed names them: a feed never points at a file that is
# not there.
gh release edit "$tag" --draft=false

# One commit, replaced each time: the branch keeps no history.
git -C "$pages" init -q -b gh-pages
git -C "$pages" add -A
git -C "$pages" -c user.name="loaf chat releases" -c user.email="releases@loaf.moe" \
  commit -q -m "Loaf Chat $version"
git -C "$pages" push --force \
  "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" gh-pages
