#!/usr/bin/env bash
# Packs the Windows bundle twice: a zip for the app's own updater, with its
# signed entry for latest.json, and Setup for people. Runs in Git Bash on the
# Windows runner.
# usage: windows.sh <version> <build> <out dir>
set -euo pipefail

version="$1"; build="$2"; out="$3"
bundle="build/windows/x64/runner/Release"
work="$(mktemp -d)"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

# As in appimage.sh: the key leaves the environment at once, and touches
# disk only for the signing.
private_key="$APPIMAGE_PRIVATE_KEY"
unset APPIMAGE_PRIVATE_KEY

test -f "$bundle/loaf-chat.exe" \
  || { echo "no loaf-chat.exe in $bundle" >&2; exit 1; }

# The bundle's contents at the zip's root: the updater unpacks it straight
# into a folder shaped like the install (lib/update/bundle_swap.dart).
zip="Loaf-Chat-$version-windows-x64.zip"
(cd "$bundle" && 7z a -tzip -r -bd "$out/$zip" '*' >/dev/null)

sha="$(sha256sum "$out/$zip" | cut -d' ' -f1)"
size="$(stat -c %s "$out/$zip")"
# Exactly Release.signedTextFor(AssetKind.windows) in
# lib/update/release_feed.dart: no last newline.
printf 'loaf-chat-windows\n%s\n%s\n%s' "$version" "$build" "$sha" > "$work/signed.txt"
(umask 077; printf '%s\n' "$private_key" > "$work/key.pem")
unset private_key
signature="$(openssl pkeyutl -sign -inkey "$work/key.pem" -rawin -in "$work/signed.txt" | base64 -w0)"
rm -f "$work/key.pem"

# publish merges this into the Linux job's latest.json.
jq -n --arg url "https://github.com/Loaf-moe/loaf-chat/releases/download/v$version/$zip" \
  --arg sha256 "$sha" --argjson size "$size" --arg signature "$signature" \
  '{windows: {url: $url, sha256: $sha256, size: $size, signature: $signature}}' \
  > "$out/windows.json"

# Inno Setup 6 comes with the runner image; if an image ever drops it,
# Chocolatey's package of the same major version stands in.
iscc="/c/Program Files (x86)/Inno Setup 6/ISCC.exe"
if [ ! -x "$iscc" ]; then
  choco install innosetup --version=6.5.4 -y --no-progress
fi
"$iscc" /Qp \
  "/DAppVersion=$version" "/DBuild=$build" \
  "/DBundle=$(cygpath -w "$(pwd)/$bundle")" "/DOutDir=$(cygpath -w "$out")" \
  windows/packaging/loaf-chat.iss
test -f "$out/Loaf-Chat-$version-Setup.exe" \
  || { echo "Setup was not built" >&2; exit 1; }
