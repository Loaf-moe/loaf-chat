#!/usr/bin/env bash
# Starts a release: tags the tip of origin/main and pushes the tag, which
# runs .github/workflows/release.yml. Without a tag, the newest release's
# patch number goes up by one. Asks before pushing.
# usage: tag.sh [tag]
set -euo pipefail
fail() { echo "$1" >&2; exit 1; }

git fetch -q --tags origin main
latest="$(git tag --list 'v*' --sort=-v:refname | head -n 1)"

if [ -n "${1:-}" ]; then
  tag="$1"
elif [ -n "$latest" ]; then
  IFS=. read -r major minor patch <<<"${latest#v}"
  tag="v$major.$minor.$((patch + 1))"
else
  tag="v0.1.0"
fi

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "tags look like v1.2.3, not $tag"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "$tag already exists"
# Version names are for people, and people read them as going up.
if [ -n "$latest" ] && [ "$(printf '%s\n' "$latest" "$tag" | sort -V | tail -n 1)" != "$tag" ]; then
  fail "$tag would come before $latest"
fi

commit="$(git rev-parse origin/main)"
# Nothing new since the last release would only rebuild it under a new name.
if [ -n "$latest" ] && [ "$(git rev-parse "$latest^{commit}")" = "$commit" ]; then
  fail "origin/main is already $latest"
fi

echo "Release $tag${latest:+ (after $latest)} from origin/main:"
git log -1 --format='  %h %s' "$commit"
read -r -p "Tag and push? [y/N] " answer
[[ "$answer" == [yY] ]] || fail "nothing tagged"

git tag "$tag" "$commit"
git push origin "refs/tags/$tag" \
  || { git tag -d "$tag" >/dev/null; fail "the push failed; $tag is untagged again"; }
echo "pushed $tag: release.yml is running"
