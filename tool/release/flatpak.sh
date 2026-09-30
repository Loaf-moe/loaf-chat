#!/usr/bin/env bash
# Commits the Linux bundle to the Flatpak repo, signed, keeping three builds.
# usage: flatpak.sh <version> <repo dir>
set -euo pipefail

version="$1"; repo="$2"
# Inside the checkout, not mktemp: flatpak-builder keeps its state in
# ./.flatpak-builder and refuses a build dir on another filesystem, which
# /tmp is inside the CI container.
build="build/flatpak"

echo "$FLATPAK_GPG_PRIVATE_KEY" | gpg --batch --import
key="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')"

flatpak-builder --force-clean --disable-rofiles-fuse \
  --repo="$repo" --default-branch=stable \
  --gpg-sign="$key" --subject="Loaf Chat $version" \
  "$build" linux/packaging/moe.loaf.chat.yml
# This build and the two before it.
flatpak build-update-repo --prune --prune-depth=2 --gpg-sign="$key" \
  --title="Loaf Chat" "$repo"
