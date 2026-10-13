#!/usr/bin/env bash
# Builds the macOS release, signs it manually with Developer ID and a
# Developer ID provisioning profile fetched through the App Store Connect
# API, packs a DMG, notarizes it, and writes Sparkle's feed. It creates
# nothing in the Apple account: Xcode is never allowed to provision, so no
# certificate or profile is minted on a runner's behalf. Run on macOS from
# the repo root.
# usage: macos.sh <version> <build> <out dir>
set -euo pipefail

version="$1"; build="$2"; out="$3"
identity="Developer ID Application: CHRISTOPHER ETIENNE THOMAS (6W2A5N37N3)"
team="6W2A5N37N3"
bundle_id="moe.loaf.chat.ios"
sparkle_version="2.8.0"
fail() { echo "::error::$1"; exit 1; }

# Before a ten-minute build, not after it.
for name in NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID \
    MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD SPARKLE_PRIVATE_KEY; do
  [ -n "${!name:-}" ] || fail "$name is missing or empty"
done

work="$(mktemp -d)"
keychain="$work/release.keychain-db"
# The key, the token and the keychain must not outlive the script, however
# it ends. mktemp made $work private to this user.
trap 'security delete-keychain "$keychain" 2>/dev/null || true; rm -rf "$work"' EXIT
echo "$NOTARY_KEY_P8" | base64 --decode > "$work/key.p8"
mkdir -p "$out"

# A keychain of our own, so codesign can use the certificate unattended.
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
# The profile must name this exact certificate, matched by SHA-1.
cert_sha1="$(security find-identity -v -p codesigning "$keychain" \
  | awk '/"Developer ID Application/ { print toupper($2); exit }')"
[ -n "$cert_sha1" ] || fail "the P12 holds no Developer ID Application identity"

b64url() { base64 | tr -d '=\n' | tr '/+' '_-'; }
# An App Store Connect token: ES256 over header.payload, valid 15 minutes
# (Apple allows 20). openssl signs ECDSA as DER SEQUENCE { r, s }; JWS wants
# r and s as 32 raw bytes each, so the DER is unpacked and padded.
# usage: asc_jwt <key.p8> <key id> <issuer id>
asc_jwt() {
  local now header payload input r s
  now="$(date +%s)"
  header="$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$2" | b64url)"
  payload="$(printf '{"iss":"%s","iat":%d,"exp":%d,"aud":"appstoreconnect-v1"}' \
    "$3" "$now" "$((now + 900))" | b64url)"
  input="$header.$payload"
  { read -r r; read -r s; } < <(printf '%s' "$input" \
    | openssl dgst -sha256 -sign "$1" \
    | openssl asn1parse -inform DER | awk -F: '/INTEGER/ { print $NF }')
  # DER drops leading zero bytes and adds one before a high bit; both go.
  r="$(printf '%064s' "$r" | tr ' ' 0)"; r="${r: -64}"
  s="$(printf '%064s' "$s" | tr ' ' 0)"; s="${s: -64}"
  printf '%s.%s' "$input" "$(printf '%s%s' "$r" "$s" | xxd -r -p | b64url)"
}

# The token goes to curl in a header file, never on a command line (where
# ps shows it) and never into the environment of what runs later.
printf 'Authorization: Bearer %s\n' \
  "$(asc_jwt "$work/key.p8" "$NOTARY_KEY_ID" "$NOTARY_ISSUER_ID")" > "$work/asc-auth"
# usage: asc <path after /v1/> <output file>. GET only.
asc() {
  curl -fsS -g -H "@$work/asc-auth" -o "$2" \
    "https://api.appstoreconnect.apple.com/v1/$1" \
    || fail "App Store Connect refused GET /v1/$1 (curl exit $?): check NOTARY_KEY_ID, NOTARY_ISSUER_ID and the key's access"
}

# Read-only: find the profile, never create one. The identifier filter
# matches prefixes too, so the exact one is picked out.
asc "bundleIds?filter[identifier]=$bundle_id&limit=200" "$work/bundles.json"
bundle_ref="$(jq -r --arg id "$bundle_id" \
  '.data[] | select(.attributes.identifier == $id) | .id' "$work/bundles.json")"
[ -n "$bundle_ref" ] || fail "App Store Connect has no bundle id $bundle_id"
asc "bundleIds/$bundle_ref/profiles?limit=200" "$work/profiles.json"
rm -f "$work/asc-auth"

# Every ACTIVE Developer ID profile is a candidate. Xcode-managed ones are
# skipped: manual signing refuses them ("is Xcode managed, but signing
# settings require a manually managed profile"). Of the rest, the one that
# names the P12's certificate and lasts longest wins.
profile=""; profile_expiry=""
mkdir "$work/candidates"
n=0
while IFS= read -r content; do
  n=$((n + 1))
  candidate="$work/candidates/$n.provisionprofile"
  echo "$content" | base64 --decode > "$candidate"
  security cms -D -i "$candidate" > "$candidate.plist"
  [ "$(plutil -extract IsXcodeManaged raw -o - "$candidate.plist" 2>/dev/null)" = true ] && continue
  count="$(plutil -extract DeveloperCertificates raw -o - "$candidate.plist")"
  i=0; named=false
  while [ "$i" -lt "$count" ]; do
    sha1="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$candidate.plist" \
      | base64 --decode | shasum -a 1 | awk '{ print toupper($1) }')"
    [ "$sha1" = "$cert_sha1" ] && named=true
    i=$((i + 1))
  done
  "$named" || continue
  expiry="$(plutil -extract ExpirationDate raw -o - "$candidate.plist")"
  if [ -z "$profile" ] || [[ "$expiry" > "$profile_expiry" ]]; then
    profile="$candidate"; profile_expiry="$expiry"
  fi
done < <(jq -r '.data[]
  | select(.attributes.profileType == "MAC_APP_DIRECT" and .attributes.profileState == "ACTIVE")
  | .attributes.profileContent' "$work/profiles.json")
[ -n "$profile" ] || fail "no ACTIVE, manually managed Developer ID profile for $bundle_id names certificate $cert_sha1. Create one at developer.apple.com: Profiles, +, Developer ID (macOS), App ID $bundle_id, that certificate. This script never creates one."
profile_uuid="$(plutil -extract UUID raw -o - "$profile.plist")"
profile_name="$(plutil -extract Name raw -o - "$profile.plist")"
echo "profile: $profile_name ($profile_uuid), expires $profile_expiry"

# Where Xcode 16 and later look; MobileDevice is where older ones did.
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  mkdir -p "$dir"
  cp "$profile" "$dir/$profile_uuid.provisionprofile"
done

plutil -lint tool/release/macos-export.plist
# The checked-in plist names no profile; this copy maps the app to the
# fetched one.
cp tool/release/macos-export.plist "$work/export.plist"
plutil -insert provisioningProfiles -dictionary "$work/export.plist"
# plutil key paths split on dots, so the bundle id's are escaped.
plutil -insert "provisioningProfiles.$(printf '%s' "$bundle_id" | sed 's/\./\\./g')" \
  -string "$profile_uuid" "$work/export.plist"
plutil -lint "$work/export.plist"

# The build runs third-party code (Flutter assemble, Run Script phases,
# SwiftPM and pub build hooks); none of it needs a secret. Signing uses the
# unlocked keychain and the installed profile, so every secret leaves the
# environment. The token was never exported, and its file is gone.
build_env=(env -u NOTARY_KEY_P8 -u NOTARY_KEY_ID -u NOTARY_ISSUER_ID
  -u MACOS_CERTIFICATE_P12 -u MACOS_CERTIFICATE_PASSWORD -u SPARKLE_PRIVATE_KEY)

"${build_env[@]}" mise exec -- flutter build macos --release --config-only \
  --build-name="$version" --build-number="$build" \
  --dart-define=LOAF_BUILD="$build" \
  --dart-define=LOAF_VERSION="$version"

# Signed manually, as Developer ID with the fetched profile: the archive
# needs a profile because communication notifications require one, and
# manual signing never asks Apple for anything. The profile reaches only the
# app: set directly, PROVISIONING_PROFILE_SPECIFIER would land on the SwiftPM
# resource bundles too, which refuse it ("does not support provisioning
# profiles"), so it is looked up by each target's WRAPPER_EXTENSION and only
# LOAF_PROFILE_app is set. ENABLE_HARDENED_RUNTIME: the project leaves it
# off, the export keeps the archive's flags, and notarization requires it.
# shellcheck disable=SC2016
"${build_env[@]}" xcodebuild archive -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$work/Runner.xcarchive" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$team" \
  'PROVISIONING_PROFILE_SPECIFIER=$(LOAF_PROFILE_$(WRAPPER_EXTENSION))' \
  LOAF_PROFILE_app="$profile_uuid" \
  ENABLE_HARDENED_RUNTIME=YES

# Re-signs every nested binary with Developer ID, inside out, and embeds the
# fetched profile.
"${build_env[@]}" xcodebuild -exportArchive -archivePath "$work/Runner.xcarchive" \
  -exportOptionsPlist "$work/export.plist" -exportPath "$work/export"

# Gates. Never ship an app that would lose its data or crash at launch.
app="$work/export/Loaf Chat.app"
archived="$work/Runner.xcarchive/Products/Applications/Loaf Chat.app"
downloader="Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
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
# Exactly what Release.entitlements asks for, plus the two identity keys
# signing always adds. The profile grants more (push, app groups, keychain
# groups); none of it may leak into the signature.
plutil -convert json -o "$work/app.entitlements.json" "$work/app.entitlements"
plutil -convert json -o "$work/wanted.json" macos/Runner/Release.entitlements
entitlement_diff="$(jq -r --slurpfile want "$work/wanted.json" '
  (keys - ["com.apple.application-identifier", "com.apple.developer.team-identifier"])
  as $have | ($want[0] | keys) as $want
  | (($have - $want) | map("extra " + .)) + (($want - $have) | map("missing " + .))
  | .[]' "$work/app.entitlements.json")"
[ -z "$entitlement_diff" ] \
  || fail "the exported entitlements differ from Release.entitlements: $(echo "$entitlement_diff" | paste -sd ";" -)"
[ -f "$app/Contents/embedded.provisionprofile" ] \
  || fail "the exported app has no embedded provisioning profile"
security cms -D -i "$app/Contents/embedded.provisionprofile" > "$work/embedded.plist"
[ "$(plutil -extract UUID raw -o - "$work/embedded.plist")" = "$profile_uuid" ] \
  || fail "the exported app embeds a profile other than the fetched $profile_uuid"
codesign --verify --deep --strict "$app" \
  || fail "the exported app fails codesign --verify --deep --strict"
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
# Notarization requires the hardened runtime.
grep -q '^CodeDirectory .*flags=.*runtime' "$work/signature.txt" \
  || fail "the exported app is not signed with the hardened runtime"
# Sparkle compares CFBundleVersion: a wrong one publishes an update that
# never installs, or one that installs forever.
info() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist" 2>/dev/null; }
[ "$(info CFBundleShortVersionString)" = "$version" ] \
  || fail "the exported app's version is $(info CFBundleShortVersionString), not $version"
[ "$(info CFBundleVersion)" = "$build" ] \
  || fail "the exported app's build is $(info CFBundleVersion), not $build"

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
