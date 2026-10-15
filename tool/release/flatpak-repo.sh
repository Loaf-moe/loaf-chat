#!/usr/bin/env bash
# Gets the Flatpak build ready inside the CI container: the Linux bundle
# unpacked where the manifest looks for it, and the repo so far from
# gh-pages, so this build lands on top of the last ones.
# usage: flatpak-repo.sh <bundle.tar> <repo dir>
set -euo pipefail

bundle="$1"; repo="$2"

# The image is Fedora-based; make sure the tools are there.
command -v git gpg tar >/dev/null || dnf install -y git gnupg2 tar
mkdir -p build/linux/x64/release
tar -xf "$bundle" -C build/linux/x64/release

# No branch yet (exit 2) is a first release; any other failure must not
# quietly drop the older builds.
url="https://github.com/${GITHUB_REPOSITORY}.git"
code=0
git ls-remote --exit-code --heads "$url" gh-pages >/dev/null || code=$?
case "$code" in
  0)
    # In the checkout, as flatpak.sh keeps its build: /tmp is another
    # filesystem inside the CI container.
    before=build/pages-before
    rm -rf "$before"
    git clone --depth 1 --branch gh-pages "$url" "$before"
    test -d "$before/repo" || { echo "::error::gh-pages has no repo/"; exit 1; }
    mv "$before/repo" "$repo"
    # Git does not keep empty directories, and ostree will not open a repo
    # without them.
    mkdir -p "$repo/tmp" "$repo/refs/remotes" "$repo/refs/mirrors" \
      "$repo/state" "$repo/extensions"
    ;;
  2) echo "no gh-pages yet: first release" ;;
  *) echo "::error::could not list gh-pages (exit $code)"; exit 1 ;;
esac
