#!/usr/bin/env bash
# Lays out get.loaf.moe's download page from its template and a latest.json.
# Separate from pages.sh so the page can be previewed without a release.
# usage: site.sh <latest.json> <out dir>
set -euo pipefail

feed="$1"; out="$2"
site="tool/release/site"

version="$(jq -er '.version' "$feed")"
appimage_url="$(jq -er '.appimage.url' "$feed")"
# The DMG sits beside the AppImage on the same GitHub Release; see macos.sh.
dmg_url="https://github.com/Loaf-moe/loaf-chat/releases/download/v$version/Loaf-Chat-$version.dmg"
# Setup is there too; the zip in the feed is for updates, not for people.
setup_url="https://github.com/Loaf-moe/loaf-chat/releases/download/v$version/Loaf-Chat-$version-Setup.exe"

mkdir -p "$out/fonts"
sed -e "s|{{VERSION}}|$version|g" \
    -e "s|{{DMG_URL}}|$dmg_url|g" \
    -e "s|{{APPIMAGE_URL}}|$appimage_url|g" \
    -e "s|{{SETUP_URL}}|$setup_url|g" \
    "$site/index.html" > "$out/index.html"
# A placeholder left in means the template grew one this script doesn't fill.
if grep -n '{{' "$out/index.html"; then
  echo "unfilled placeholder in the download page" >&2
  exit 1
fi

# Plain names: brackets in a URL are asking for trouble. The OFL wants its
# licence to travel with the fonts.
cp "assets/fonts/Lora[wght].ttf" "$out/fonts/Lora.ttf"
cp "assets/fonts/Lora-Italic[wght].ttf" "$out/fonts/Lora-Italic.ttf"
cp "assets/fonts/Outfit[wght].ttf" "$out/fonts/Outfit.ttf"
cp assets/fonts/IBMPlexMono-Regular.ttf "$out/fonts/"
cp assets/fonts/OFL-Lora.txt assets/fonts/OFL-Outfit.txt assets/fonts/OFL-IBMPlexMono.txt "$out/fonts/"
