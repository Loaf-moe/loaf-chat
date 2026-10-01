# Loaf Chat — iOS on TestFlight

The README already says phones get Loaf Chat through TestFlight; nothing
makes that true. This spec does: the same tag on `main` that releases the
desktop apps also builds iOS, signs it, uploads it to App Store Connect, and
the build reaches every phone in the internal **Testing** group with nobody
clicking anything. It amends `2026-09-20-loaf-native-design.md`
("Distribution": TestFlight, which it planned to run by hand from a Mac) and
extends the release pipeline from `2026-09-29-desktop-updates-design.md`,
whose update seam already keeps phones on `NoUpdater`.

## Scope

**In:**

- The iOS bundle id becomes `moe.loaf.chat.ios`, the App Store Connect
  record that already exists.
- The export-compliance answer, declared in the build.
- An `ios` job in `release.yml` and a `tool/release/ios.sh` it runs.
- Repo checks that keep the identity and export settings from drifting.
- A one-time setup checklist, and a sentence in the README's Releasing
  section.

**Out:**

| Deferred | Why |
|---|---|
| External TestFlight groups | Testing is internal; external means Beta App Review on every version |
| The App Store | Not a v1 goal (base design, "Distribution") |
| Assigning builds to the group from CI | Testing's own automatic distribution does it (native first) |
| Waiting in CI for Apple's processing | A macOS runner idling up to 30 minutes, to learn what Apple emails anyway |
| A CI check that automatic distribution is still on | Needs a JWT signer for one guard; the setup checklist covers it |
| Automatic retries of a failed upload | Hides real failures; re-run the job |
| Changing the macOS bundle id | Stays `moe.loaf.native` (desktop-updates spec) |
| Android | Non-goal for v1 |

## Findings (checked 2026-09-30)

**Verified in the project:**

- **The release pipeline** (`.github/workflows/release.yml`) has `version`,
  `macos`, `linux`, `flatpak` and `publish` jobs. Nothing builds iOS.
- **The iOS target** signs automatically with team `6W2A5N37N3` and bundle
  id `moe.loaf.native`; `RunnerTests` is `moe.loaf.native.RunnerTests`.
  Deployment target iOS 15.0. Plugins come in through Swift Package Manager
  (`FlutterGeneratedPluginSwiftPackage`); there is no Podfile.
- **Versions** are already `$(FLUTTER_BUILD_NAME)` and
  `$(FLUTTER_BUILD_NUMBER)` in `ios/Runner/Info.plist`, and
  `CFBundleDisplayName` is already `Loaf Chat`.
- **The SSO callback scheme** is the literal `SsoBrowser.scheme =
  'moe.loaf.native'` (`lib/matrix/sso_browser.dart`), not derived from the
  bundle id. iOS's web authentication session does not need the scheme
  registered, so the Kanidm redirect URI is untouched by the rename.
- **The 1024 pt marketing icon** has no alpha channel, as App Store Connect
  requires.
- **Secrets** in the `release` environment include `NOTARY_KEY_P8`,
  `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`: an App Store Connect API key, the
  same one the earlier Loaf Chat used for its App Store Connect work.
- **Only one usage string** is declared, `NSPhotoLibraryUsageDescription`.
  There is no `PrivacyInfo.xcprivacy` in `ios/Runner`.

**Decided with Chris:**

- **Testing is an internal group.** A build reaches it as soon as processing
  ends; no Beta App Review.
- **`ITSAppUsesNonExemptEncryption = false`.** The app's encryption (TLS,
  and Matrix E2EE through vodozemac: AES, Curve25519, HMAC-SHA256) is
  standard algorithms only. This is Chris's declaration to Apple.
- **Cloud signing**, with the existing API key. No `.p12`, no provisioning
  profile in secrets.
- **Testing's automatic distribution** puts each build in the group.

**Not verified. The rehearsal settles each:**

- **An unsigned archive, signed at export.** `xcodebuild -exportArchive`
  with `-allowProvisioningUpdates` is reported (Xcode 13 and later) to sign
  an archive built with `CODE_SIGNING_ALLOWED=NO` using the cloud-managed
  distribution certificate. Fallback if not: archive signed with the
  cloud-managed distribution identity directly. Neither needs a `.p12`, and
  neither creates development certificates.
- **The key's role.** Cloud-managed distribution certificates need an
  **Admin** key. If the key is lower, export fails with a cloud signing
  permission error; the fix is raising its role in App Store Connect, with
  no change to code or secrets.
- **Processing warnings.** App Store Connect may flag missing
  required-reason API declarations (`ITMS-91053`) or missing usage strings
  for linked camera or microphone APIs (`ITMS-90683`). If it does, the
  manifest or the strings join this work.

## App identity

| Thing | Value |
|---|---|
| iOS Runner `PRODUCT_BUNDLE_IDENTIFIER` (Debug, Release, Profile) | `moe.loaf.chat.ios` |
| iOS `RunnerTests` `PRODUCT_BUNDLE_IDENTIFIER` | `moe.loaf.chat.ios.RunnerTests` |
| `ITSAppUsesNonExemptEncryption` in `ios/Runner/Info.plist` | `false` |
| macOS bundle id | `moe.loaf.native` (unchanged) |
| `SsoBrowser.scheme` | `moe.loaf.native` (unchanged) |
| Version name and build number | The `version` job's, same as desktop |

Because desktop and iOS share one build number, a tester's phone and laptop
name the same build the same way. The number is `git rev-list --count`, so
it only goes up, which App Store Connect requires just as Sparkle and the
AppImage updater do.

## The pipeline

### `tool/release/ios.sh <version> <build>`

Next to `macos.sh`, and written like it. Run on macOS from the repo root.

1. **Fail early.** If `NOTARY_KEY_P8`, `NOTARY_KEY_ID` or `NOTARY_ISSUER_ID`
   is empty, stop with `::error::` naming it, before any build.
2. **The key on disk, briefly.** Decode `NOTARY_KEY_P8` into a `mktemp -d`
   folder; a `trap` removes the folder on any exit.
3. **Configure.** `flutter build ios --release --config-only
   --build-name=<version> --build-number=<build>
   --dart-define=LOAF_BUILD=<build>`.
4. **Archive, unsigned.** `xcodebuild archive -workspace
   ios/Runner.xcworkspace -scheme Runner -configuration Release
   -destination 'generic/platform=iOS' -archivePath <tmp>/Runner.xcarchive
   CODE_SIGNING_ALLOWED=NO`. Signing here would make each fresh runner mint
   a development certificate, and Apple caps those.
5. **Sign and upload.** `xcodebuild -exportArchive -archivePath …
   -exportOptionsPlist tool/release/ios-export.plist -exportPath <tmp>/export
   -allowProvisioningUpdates -authenticationKeyPath <tmp>/key.p8
   -authenticationKeyID "$NOTARY_KEY_ID" -authenticationKeyIssuerID
   "$NOTARY_ISSUER_ID"`.
6. **A build already there is success.** If export fails, and its output is
   App Store Connect's redundant-binary rejection for this build number,
   print `::notice::already on TestFlight` and exit 0. Every other failure
   exits nonzero with Apple's message in the log.

### `tool/release/ios-export.plist`

Committed, and nothing secret in it:

| Key | Value |
|---|---|
| `method` | `app-store-connect` |
| `destination` | `upload` |
| `signingStyle` | `automatic` |
| `teamID` | `6W2A5N37N3` |

### The `ios` job

In `release.yml`: `needs: version`, `runs-on: macos-latest`,
`environment: release`. Checkout, `jdx/mise-action`, then
`tool/release/ios.sh` with the version job's name and build, and the three
`NOTARY_*` secrets in its environment. A comment says the one App Store
Connect API key both notarizes macOS and signs and uploads iOS; the secrets
keep their names, because renaming means re-entering values GitHub cannot
read back.

It runs alongside `macos` and `linux`. **`publish` does not need it:** a
slow or failing App Store Connect never holds back the desktop release or
get.loaf.moe. TestFlight is the only place the iOS build goes; nothing iOS
lands in the GitHub Release.

## What "done" means

**A green `ios` job means App Store Connect accepted the upload.** Nothing
more. Apple then processes the build (usually 5–30 minutes), and Testing's
automatic distribution hands it to phones. A processing failure reaches the
account holder by email; CI never sees it.

**Re-running a tag.** "Re-run failed jobs", the usual fix for a flaky
desktop step, leaves a green `ios` job alone. "Re-run all jobs" uploads the
same build number again; step 6 turns Apple's rejection into a notice,
because the build genuinely is there. If Apple's wording changes, the job
goes red: it fails closed, never open.

**A tag on an older commit** carries a lower build number, and App Store
Connect rejects it loudly. That is the right outcome; the script adds
nothing.

## One-time setup

1. The App Store Connect API key behind `NOTARY_*` has the **Admin** role.
2. The **Testing** group (App Store Connect → Loaf Chat → TestFlight) has
   **automatic distribution** on.
3. Testers are in Testing and have the TestFlight app.

## Testing

**Repo checks** — in the Dart test suite if one fits naturally, otherwise a
`tool/release/check-ios.sh` the `ios` job runs first:

- Runner's `PRODUCT_BUNDLE_IDENTIFIER` is `moe.loaf.chat.ios` in all three
  configurations, and `moe.loaf.native` appears nowhere in the iOS target.
- `ITSAppUsesNonExemptEncryption` is `false` in `ios/Runner/Info.plist`.
- `tool/release/ios-export.plist` passes `plutil -lint` and has the method,
  destination and team above.
- `SsoBrowser.scheme` is still `moe.loaf.native`, so nobody "fixes" it to
  match the new bundle id.

**The rehearsal** is the acceptance test:

1. On a Mac, run `tool/release/ios.sh` with the key in the environment and a
   throwaway build number. This proves the unsigned-archive, sign-at-export
   path before any tag.
2. Push a tag. `ios` goes green; the desktop jobs and `publish` never wait
   on it.
3. Within about 30 minutes the build is **Ready to Test** in Testing, with
   no compliance prompt, and appears in TestFlight on a tester's iPhone.
4. "Re-run all jobs" on that tag: `ios` passes with
   `::notice::already on TestFlight`.
5. Apple's processing email carries no `ITMS-91053` or `ITMS-90683`; if it
   does, the fix joins this work before it counts as done.

## Docs

README line 14 ("Phones get Loaf Chat through TestFlight") stays; it becomes
true. The Releasing section gains one sentence: the same tag sends iOS to
TestFlight's Testing group.
