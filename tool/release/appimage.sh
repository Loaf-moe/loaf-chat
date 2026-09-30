#!/usr/bin/env bash
# Packs the Linux bundle as an AppImage and writes the signed latest.json.
# usage: appimage.sh <version> <build> <out dir>
set -euo pipefail

version="$1"; build="$2"; out="$3"
bundle="build/linux/x64/release/bundle"
work="$(mktemp -d)"
appdir="$work/Loaf-Chat.AppDir"
mkdir -p "$out" "$appdir"

# The key goes to a file now and out of the environment, so nothing
# downloaded or run below can read it.
echo "$APPIMAGE_PRIVATE_KEY" > "$work/key.pem"
unset APPIMAGE_PRIVATE_KEY

cp -r "$bundle"/. "$appdir/"
cp linux/packaging/moe.loaf.chat.desktop "$appdir/"
cp macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png "$appdir/moe.loaf.chat.png"
cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
exec "$(dirname "$(readlink -f "$0")")/loaf-chat" "$@"
EOF
chmod +x "$appdir/AppRun"

# Pinned: this tool packs the app we sign. To bump, download the new tagged
# release's x86_64 asset, run `sha256sum` on it, and update both lines.
tool_url=https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
tool_sha=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
curl -fsSL -o "$work/appimagetool" "$tool_url"
echo "$tool_sha  $work/appimagetool" | sha256sum -c -
chmod +x "$work/appimagetool"
name="Loaf-Chat-$version-x86_64.AppImage"
# Runners have no FUSE, so the tool unpacks itself to run.
ARCH=x86_64 "$work/appimagetool" --appimage-extract-and-run "$appdir" "$out/$name"

sha="$(sha256sum "$out/$name" | cut -d' ' -f1)"
size="$(stat -c %s "$out/$name")"
# Exactly Release.signedText in lib/update/release_feed.dart: no last newline.
printf 'loaf-chat-appimage\n%s\n%s\n%s' "$version" "$build" "$sha" > "$work/signed.txt"
signature="$(openssl pkeyutl -sign -inkey "$work/key.pem" -rawin -in "$work/signed.txt" | base64 -w0)"

jq -n --arg version "$version" --argjson build "$build" \
  --arg url "https://github.com/Loaf-moe/loaf-chat/releases/download/v$version/$name" \
  --arg sha256 "$sha" --argjson size "$size" --arg signature "$signature" \
  '{version: $version, build: $build,
    appimage: {url: $url, sha256: $sha256, size: $size, signature: $signature}}' \
  > "$out/latest.json"
