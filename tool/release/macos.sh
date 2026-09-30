#!/usr/bin/env bash
# Signs the macOS release build with Developer ID, packs a DMG, notarizes
# it, and writes Sparkle's feed. Run on macOS after `flutter build macos`.
# usage: macos.sh <version> <out dir>
set -euo pipefail

version="$1"; out="$2"
app="build/macos/Build/Products/Release/Loaf Chat.app"
identity="Developer ID Application: CHRISTOPHER ETIENNE THOMAS (6W2A5N37N3)"
sparkle_version="2.8.0"
work="$(mktemp -d)"
mkdir -p "$out"

# A keychain of our own, so codesign can use the certificate unattended.
keychain="$work/release.keychain-db"
security create-keychain -p "" "$keychain"
security set-keychain-settings "$keychain"
security unlock-keychain -p "" "$keychain"
echo "$MACOS_CERTIFICATE_P12" | base64 --decode > "$work/certificate.p12"
security import "$work/certificate.p12" -k "$keychain" \
  -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
# Imported; the decoded file has no more work to do on disk.
rm -f "$work/certificate.p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" login.keychain-db

# The entitlements as Xcode expanded them: the file in the repo still has
# $(PRODUCT_BUNDLE_IDENTIFIER) in it, which codesign would take literally.
codesign -d --entitlements "$work/app.entitlements" --xml "$app"
# The ad-hoc Release build carries get-task-allow. Notarization rejects it,
# and it would let a debugger attach to the shipped app.
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$work/app.entitlements" 2>/dev/null || true

sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }

# Inside out. Sparkle's helpers first, as its sandboxing guide orders them.
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
find "$app/Contents/Frameworks" -depth \( -name '*.dylib' -o -name '*.framework' \) -print0 \
  | while IFS= read -r -d '' item; do sign "$item"; done
sign --entitlements "$work/app.entitlements" "$app"
codesign --verify --deep --strict "$app"

stage="$work/dmg"; mkdir "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
dmg="$out/Loaf-Chat-$version.dmg"
hdiutil create -volname "Loaf Chat" -srcfolder "$stage" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"

echo "$NOTARY_KEY_P8" | base64 --decode > "$work/notary.p8"
# A nonzero exit is judged by the status below, so the log can be fetched first.
submission="$(xcrun notarytool submit "$dmg" --key "$work/notary.p8" \
  --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait \
  --output-format json)" || true
echo "$submission"
status="$(echo "$submission" | jq -r '.status // empty')"
if [ "$status" != "Accepted" ]; then
  id="$(echo "$submission" | jq -r '.id // empty')"
  # The log says why; without it a rejection is a dead end.
  [ -n "$id" ] && xcrun notarytool log "$id" --key "$work/notary.p8" \
    --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" || true
  rm -f "$work/notary.p8"
  echo "notarization did not end Accepted (status: ${status:-none})" >&2
  exit 1
fi
rm -f "$work/notary.p8"
xcrun stapler staple "$dmg"

mkdir "$work/sparkle"
# Pinned to 2.8.0. To bump SPARKLE_VERSION, download the new tarball, run
# `shasum -a 256` on it and update sparkle_sha.
sparkle_sha="fd5681ee92bf238aaac2d08214ceaf0cc8976e452d7f882d80bac1e61581f3b1"
curl -fsSL -o "$work/sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
echo "$sparkle_sha  $work/sparkle.tar.xz" | shasum -a 256 -c -
tar -xJf "$work/sparkle.tar.xz" -C "$work/sparkle"
feed="$work/feed"; mkdir "$feed"
cp "$dmg" "$feed/"
# Only the Sparkle key, on stdin: the signing and notary secrets stay out of
# this downloaded tool's environment.
echo "$SPARKLE_PRIVATE_KEY" | env -u MACOS_CERTIFICATE_P12 -u MACOS_CERTIFICATE_PASSWORD \
  -u NOTARY_KEY_P8 -u NOTARY_KEY_ID -u NOTARY_ISSUER_ID \
  "$work/sparkle/bin/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "https://github.com/Loaf-moe/loaf-chat/releases/download/v$version/" \
  -o "$out/appcast.xml" "$feed"
