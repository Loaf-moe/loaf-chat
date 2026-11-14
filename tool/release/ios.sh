#!/usr/bin/env bash
# Builds the iOS release, signs it with Apple's cloud-managed distribution
# certificate, and uploads it to App Store Connect. The Testing group's
# automatic distribution takes it to phones from there. Run on macOS from the
# repo root.
# usage: ios.sh <version> <build>
set -euo pipefail

version="$1"; build="$2"

# Before a ten-minute build, not after it.
for name in NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID; do
  [ -n "${!name:-}" ] || { echo "::error::$name is missing or empty"; exit 1; }
done

work="$(mktemp -d)"
# The key must not outlive the script, however it ends.
trap 'rm -rf "$work"' EXIT
echo "$NOTARY_KEY_P8" | base64 --decode > "$work/key.p8"

plutil -lint tool/release/ios-export.plist tool/release/ios-export-local.plist

mise exec -- flutter build ios --release --config-only \
  --build-name="$version" --build-number="$build" \
  --dart-define=LOAF_BUILD="$build" \
  --dart-define=LOAF_VERSION="$version"

# Unsigned: signing here would mint a development certificate on every fresh
# runner, and Apple caps those. Export signs it for distribution instead.
xcodebuild archive -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$work/Runner.xcarchive" CODE_SIGNING_ALLOWED=NO

# The archive is unsigned; export signs it. Prove the signed app and its
# extension carry push and the App Group before anything reaches Apple.
xcodebuild -exportArchive -archivePath "$work/Runner.xcarchive" \
  -exportOptionsPlist tool/release/ios-export-local.plist \
  -exportPath "$work/check" -allowProvisioningUpdates \
  -authenticationKeyPath "$work/key.p8" \
  -authenticationKeyID "$NOTARY_KEY_ID" \
  -authenticationKeyIssuerID "$NOTARY_ISSUER_ID"
unzip -q "$work/check/"*.ipa -d "$work/ipa"
app="$work/ipa/Payload/Runner.app"
appex="$app/PlugIns/NotifyService.appex"
ents() { codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -convert json -o - -- -; }

# Every check runs, then one verdict: a release that is missing two things
# should say both, so the next attempt fixes both.
missing=""
want() { # <what> <file> <pattern>
  ents "$2" | grep -q "$3" || missing="$missing
  $1"
}
want "Runner.app lacks the App Group" "$app" '"group.moe.loaf.chat"'
want "NotifyService.appex lacks the App Group" "$appex" '"group.moe.loaf.chat"'
want "Runner.app lacks aps-environment=production" "$app" '"aps-environment":"production"'
want "NotifyService.appex lacks the filtering entitlement" "$appex" \
  '"com.apple.developer.usernotifications.filtering":true'
# The extension dlopens exactly this path at <appex>/../../Frameworks.
[ -d "$app/Frameworks/loaf_push.framework" ] \
  || missing="$missing
  loaf_push is not in the app's Frameworks"
# UNNotificationSound(named: "chime.caf") resolves against the app bundle,
# not the extension's; without it a push plays iOS's default sound.
[ -f "$app/chime.caf" ] \
  || missing="$missing
  chime.caf is not in the app bundle"

if [ -n "$missing" ]; then
  # What the signed build actually carries, so the next run does not need
  # another release to find out. Entitlements the provisioning profile does
  # not grant are dropped silently at export, so this is usually the
  # profile rather than the project.
  echo "Runner.app entitlements:"; ents "$app"
  echo "NotifyService.appex entitlements:"; ents "$appex"
  echo "::error::the signed build is missing:$missing"
  exit 1
fi

# Signs with the cloud-managed certificate and uploads, in one step.
status=0
xcodebuild -exportArchive -archivePath "$work/Runner.xcarchive" \
  -exportOptionsPlist tool/release/ios-export.plist \
  -exportPath "$work/export" -allowProvisioningUpdates \
  -authenticationKeyPath "$work/key.p8" \
  -authenticationKeyID "$NOTARY_KEY_ID" \
  -authenticationKeyIssuerID "$NOTARY_ISSUER_ID" \
  2>&1 | tee "$work/export.log" || status=$?

if [ "$status" -ne 0 ]; then
  # "Re-run all jobs" uploads the same build again. It really is there, so
  # that one rejection is success; any other wording fails closed.
  if grep -qi 'redundant binary upload' "$work/export.log" \
      && grep -q "build number '$build'" "$work/export.log"; then
    echo "::notice::build $build is already on TestFlight"
    exit 0
  fi
  echo "::error::the upload failed; Apple's message is above"
  exit "$status"
fi
