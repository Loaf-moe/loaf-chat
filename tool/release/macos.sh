#!/usr/bin/env bash
# Builds the macOS release, signs it with Developer ID through Apple's cloud
# signing (as ios.sh does), packs a DMG, notarizes it, and writes Sparkle's
# feed. Run on macOS from the repo root.
# usage: macos.sh <version> <build> <out dir>
set -euo pipefail

version="$1"; build="$2"; out="$3"
identity="Developer ID Application: CHRISTOPHER ETIENNE THOMAS (6W2A5N37N3)"
sparkle_version="2.8.0"

# Before a ten-minute build, not after it.
for name in NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID \
    MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD SPARKLE_PRIVATE_KEY; do
  [ -n "${!name:-}" ] || { echo "::error::$name is missing or empty"; exit 1; }
done

work="$(mktemp -d)"
keychain="$work/release.keychain-db"
# The key and the keychain must not outlive the script, however it ends.
trap 'security delete-keychain "$keychain" 2>/dev/null || true; rm -rf "$work"' EXIT
echo "$NOTARY_KEY_P8" | base64 --decode > "$work/key.p8"
mkdir -p "$out"

# A keychain of our own, so codesign can use the certificate unattended. The
# DMG is signed with it, and the export may sign with it too rather than mint
# a cloud-managed certificate.
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

plutil -lint tool/release/macos-export.plist

mise exec -- flutter build macos --release --config-only \
  --build-name="$version" --build-number="$build" \
  --dart-define=LOAF_BUILD="$build" \
  --dart-define=LOAF_VERSION="$version"

auth=(-authenticationKeyPath "$work/key.p8"
  -authenticationKeyID "$NOTARY_KEY_ID"
  -authenticationKeyIssuerID "$NOTARY_ISSUER_ID")

# Signed, unlike ios.sh's archive. Exported from an unsigned archive, the app
# came out with no entitlements and no provisioning profile at all: no
# sandbox (a different, empty data store), no communication notifications,
# no Sparkle mach-lookup exception. An ad-hoc archive is refused outright,
# because the communication entitlement needs a profile. Signing here bakes
# Release.entitlements in, and the export keeps them. Automatic signing
# fetches the development profile and certificate through the API key.
# Signed as Apple Development, not Developer ID: Xcode refuses a Developer ID
# identity under automatic signing ("Runner is automatically signed for
# development, but a conflicting code signing identity Developer ID
# Application has been manually specified"). The risk: a fresh runner holds
# no development certificate, so each release may make a new one, and Apple
# caps those. If a run fails on that cap, revoke the stale "Apple
# Development" certificates the releases made.
xcodebuild archive -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$work/Runner.xcarchive" \
  -allowProvisioningUpdates "${auth[@]}"

# Re-signs every nested binary with Developer ID, inside out, and embeds the
# Developer ID provisioning profile that communication notifications need.
xcodebuild -exportArchive -archivePath "$work/Runner.xcarchive" \
  -exportOptionsPlist tool/release/macos-export.plist \
  -exportPath "$work/export" -allowProvisioningUpdates "${auth[@]}"

# Gates. Never ship an app that would lose its data or crash at launch.
app="$work/export/Loaf Chat.app"
archived="$work/Runner.xcarchive/Products/Applications/Loaf Chat.app"
downloader="Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
fail() { echo "::error::$1"; exit 1; }
entitlement() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$work/app.entitlements" 2>/dev/null
}
codesign -d --entitlements - --xml "$app" > "$work/app.entitlements"
[ "$(entitlement com.apple.security.app-sandbox)" = true ] \
  || fail "the exported app is not sandboxed: it would open an empty container"
[ "$(entitlement com.apple.developer.usernotifications.communication)" = true ] \
  || fail "the exported app lacks communication notifications"
entitlement com.apple.security.temporary-exception.mach-lookup.global-name >/dev/null \
  || fail "the exported app lacks Sparkle's mach-lookup exception"
# A literal $( would mean the export signed the repo's file as written.
# shellcheck disable=SC2016
! grep -q '\$(' "$work/app.entitlements" \
  || fail "the exported entitlements have an unexpanded build setting"
! entitlement com.apple.security.get-task-allow >/dev/null \
  || fail "the exported app carries get-task-allow"
[ -f "$app/Contents/embedded.provisionprofile" ] \
  || fail "the exported app has no embedded provisioning profile"
codesign --verify --deep --strict "$app"
# The export re-signs Sparkle's helpers and must leave the Downloader's
# entitlements as Sparkle shipped them (none, in 2.8.0).
codesign -d --entitlements - --xml "$app/$downloader" > "$work/downloader.entitlements"
codesign -d --entitlements - --xml "$archived/$downloader" > "$work/downloader.archived"
cmp -s "$work/downloader.entitlements" "$work/downloader.archived" \
  || fail "the export changed Downloader.xpc's entitlements"
# Sparkle only uses the Downloader when SUEnableDownloaderService is on; the
# app downloads with its own network.client otherwise. Turned on, the
# Downloader must be able to reach the network itself.
if [ "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableDownloaderService' \
    "$app/Contents/Info.plist" 2>/dev/null)" = true ]; then
  [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' \
      "$work/downloader.entitlements" 2>/dev/null)" = true ] \
    || fail "SUEnableDownloaderService is on, but Downloader.xpc lacks network.client"
fi
# Read whole first: grep -q would close the pipe early, and pipefail would
# count codesign's SIGPIPE as a failure.
codesign -dvv "$app" > "$work/signature.txt" 2>&1
grep -q '^Authority=Developer ID Application' "$work/signature.txt" \
  || fail "the exported app is not signed with Developer ID"

stage="$work/dmg"; mkdir "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
dmg="$out/Loaf-Chat-$version.dmg"
hdiutil create -volname "Loaf Chat" -srcfolder "$stage" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"

# A nonzero exit is judged by the status below, so the log can be fetched first.
submission="$(xcrun notarytool submit "$dmg" --key "$work/key.p8" \
  --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait \
  --output-format json)" || true
echo "$submission"
status="$(echo "$submission" | jq -r '.status // empty')"
if [ "$status" != "Accepted" ]; then
  id="$(echo "$submission" | jq -r '.id // empty')"
  # The log says why; without it a rejection is a dead end.
  [ -n "$id" ] && xcrun notarytool log "$id" --key "$work/key.p8" \
    --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" || true
  echo "notarization did not end Accepted (status: ${status:-none})" >&2
  exit 1
fi
# Done with the key before a downloaded tool runs below.
rm -f "$work/key.p8"
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
