#!/usr/bin/env bash
# Renders the app icons for every platform from the SVGs beside this script.
# The mark is the legacy app's loaf.svg (tile.svg here), so the two apps show
# the same icon. Each platform gets the framing its own launcher expects:
#   ios.svg    full-bleed square; iOS rounds the corners itself
#   macos.svg  the tile on Apple's 824-in-1024 grid, with its shadow
#   tile.svg   the rounded tile as is, for Linux and pre-8.0 Android
# Android 8.0 and up draws the vector adaptive icon in res/, not these PNGs.
# Needs Inkscape. usage: tool/icons/render.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

src=tool/icons
png() { # <svg> <px> <out> [extra inkscape flags]
  inkscape "$1" --export-type=png --export-width="$2" --export-height="$2" \
    --export-filename="$3" "${@:4}" 2>/dev/null
}

ios=ios/Runner/Assets.xcassets/AppIcon.appiconset
for spec in 20x20@1x:20 20x20@2x:40 20x20@3x:60 29x29@1x:29 29x29@2x:58 \
  29x29@3x:87 40x40@1x:40 40x40@2x:80 40x40@3x:120 60x60@2x:120 60x60@3x:180 \
  76x76@1x:76 76x76@2x:152 83.5x83.5@2x:167 1024x1024@1x:1024; do
  # No alpha channel: App Store Connect rejects an icon that has one.
  png "$src/ios.svg" "${spec#*:}" "$ios/Icon-App-${spec%:*}.png" \
    --export-png-color-mode=RGB_8
done

for px in 16 32 64 128 256 512 1024; do
  png "$src/macos.svg" "$px" \
    "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$px.png"
done

for spec in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  png "$src/tile.svg" "${spec#*:}" \
    "android/app/src/main/res/mipmap-${spec%:*}/ic_launcher.png"
done

cp "$src/tile.svg" linux/packaging/moe.loaf.chat.svg
png "$src/tile.svg" 512 linux/packaging/moe.loaf.chat.png
