#!/usr/bin/env bash
# Signs the macOS release build with Developer ID, packs a DMG, notarizes
# it, and writes Sparkle's feed. Run on macOS after `flutter build macos`.
# usage: macos.sh <version> <out dir>
set -euo pipefail

version="$1"; out="$2"
app="build/macos/Build/Products/Release/Loaf Chat.app"
identity="Developer ID Application: CHRISTOPHER ETIENNE THOMAS (6W2A5N37N3)"
sparkle_version="${SPARKLE_VERSION:-2.8.0}"
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
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" login.keychain-db

# The entitlements as Xcode expanded them: the file in the repo still has
# $(PRODUCT_BUNDLE_IDENTIFIER) in it, which codesign would take literally.
codesign -d --entitlements "$work/app.entitlements" --xml "$app"

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
xcrun notarytool submit "$dmg" --key "$work/notary.p8" \
  --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
# Fails unless the notary accepted it, which is the check we want.
xcrun stapler staple "$dmg"

mkdir "$work/sparkle"
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" \
  | tar -xJ -C "$work/sparkle"
feed="$work/feed"; mkdir "$feed"
cp "$dmg" "$feed/"
echo "$SPARKLE_PRIVATE_KEY" | "$work/sparkle/bin/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "https://github.com/Loaf-moe/loaf-chat/releases/download/v$version/" \
  -o "$out/appcast.xml" "$feed"
