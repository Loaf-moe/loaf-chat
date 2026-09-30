#!/usr/bin/env bash
# Lays out what get.loaf.moe serves.
# usage: pages.sh <dist dir with appcast.xml, latest.json, repo/> <pages dir>
set -euo pipefail

dist="$1"; pages="$2"
mkdir -p "$pages"
cp -r "$dist/repo" "$pages/repo"
cp "$dist/appcast.xml" "$dist/latest.json" "$pages/"
echo "get.loaf.moe" > "$pages/CNAME"
# Without this Pages runs Jekyll, which drops the repo's dot-prefixed files.
touch "$pages/.nojekyll"

cat > "$pages/loaf-chat.flatpakref" <<EOF
[Flatpak Ref]
Name=moe.loaf.chat
Branch=stable
Title=Loaf Chat
Url=https://get.loaf.moe/repo/
IsRuntime=false
RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo
GPGKey=$(gpg --dearmor < tool/release/keys/flatpak.asc | base64 -w0)
EOF
