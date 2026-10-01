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

plutil -lint tool/release/ios-export.plist

mise exec -- flutter build ios --release --config-only \
  --build-name="$version" --build-number="$build" \
  --dart-define=LOAF_BUILD="$build"

# Unsigned: signing here would mint a development certificate on every fresh
# runner, and Apple caps those. Export signs it for distribution instead.
xcodebuild archive -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$work/Runner.xcarchive" CODE_SIGNING_ALLOWED=NO

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
