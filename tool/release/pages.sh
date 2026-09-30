#!/usr/bin/env bash
# Lays out what get.loaf.moe serves.
# usage: pages.sh <dist dir with appcast.xml, latest.json, repo/> <pages dir>
set -euo pipefail

dist="$1"; pages="$2"
# Without the key the flatpakref would install nothing signed; stop instead.
test -s tool/release/keys/flatpak.asc \
  || { echo "tool/release/keys/flatpak.asc is missing or empty" >&2; exit 1; }
mkdir -p "$pages"
cp -r "$dist/repo" "$pages/repo"
cp "$dist/appcast.xml" "$dist/latest.json" "$pages/"
echo "get.loaf.moe" > "$pages/CNAME"
# Without this Pages runs Jekyll, which drops the repo's dot-prefixed files.
touch "$pages/.nojekyll"

# Assigned here, not inside the heredoc, so a failure stops the script.
gpgkey="$(gpg --dearmor < tool/release/keys/flatpak.asc | base64 -w0)"
test -n "$gpgkey" || { echo "flatpak.asc produced an empty GPG key" >&2; exit 1; }

cat > "$pages/loaf-chat.flatpakref" <<EOF
[Flatpak Ref]
Name=moe.loaf.chat
Branch=stable
Title=Loaf Chat
Url=https://get.loaf.moe/repo/
IsRuntime=false
RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo
GPGKey=$gpgkey
EOF
