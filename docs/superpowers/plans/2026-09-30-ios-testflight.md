# iOS on TestFlight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The tag on `main` that releases the desktop apps also builds iOS, signs it with Apple's cloud signing, uploads it to App Store Connect, and the internal **Testing** group's automatic distribution puts it on testers' phones.

**Architecture:**
- **Identity:** the iOS target becomes `moe.loaf.chat.ios` and declares its export compliance in `Info.plist`. macOS and the SSO scheme stay `moe.loaf.native`.
- **One script, `tool/release/ios.sh`,** configures Flutter, archives unsigned, then signs and uploads in one `xcodebuild -exportArchive` driven by the committed `tool/release/ios-export.plist`.
- **One job, `ios`,** in `release.yml`, alongside `macos` and `linux`. `publish` never waits for it. Nothing in CI assigns the group: Testing's own automatic distribution does.

**Tech Stack:** Flutter 3.47.5 via `mise exec -- flutter`; Xcode's `xcodebuild` (archive, and export with `-allowProvisioningUpdates` and API-key authentication); bash for the release script, like its neighbours; `flutter test` for the repo checks; GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-30-ios-testflight-design.md`. Read it first, including its **Findings**.

**Not rehearsed.** The unsigned-archive, sign-at-export path, the key's role, and the wording of Apple's redundant-upload rejection are all settled by Task 5. If the code disagrees with this plan, stop and say so.

**Two tasks need Chris, not an agent:** Task 4 (App Store Connect settings) and Task 5 (the rehearsal, which uses the real key and uploads a real build). Stop at each and hand over.

## Global Constraints

- **Identifiers, exactly:**
  - iOS Runner bundle id, all three configurations: `moe.loaf.chat.ios`
  - iOS RunnerTests bundle id, all three configurations: `moe.loaf.chat.ios.RunnerTests`
  - macOS bundle id: `moe.loaf.native` (unchanged; `macos/` is not touched)
  - `SheetSsoBrowser.scheme`: `moe.loaf.native` (unchanged)
  - Team: `6W2A5N37N3`
- **`ITSAppUsesNonExemptEncryption` is `false`.** Chris's declaration; do not change it.
- **The key's secrets keep their names:** `NOTARY_KEY_P8` (base64 of the `.p8`), `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`. No new secrets.
- **Version name and build number come from the `version` job,** the same ones desktop uses.
- **`publish` does not need `ios`.**
- **No `.p12`, no provisioning profile, no development certificate** anywhere in the pipeline.
- **The key never outlives the script,** on success or failure.
- **A failure fails closed.** Only App Store Connect's redundant-binary rejection *for this build number* turns into success.
- **No automatic retries, no polling App Store Connect, no group API calls.**
- **Existing tests pass unchanged.**

## Review Focus

1. **A tag re-run with "Re-run all jobs"** uploads the same build again; the job should pass with a notice, because the build is genuinely there. (Task 2, `a build already on TestFlight is not a failure`.)
2. **A redundant-upload rejection naming a different build number** must not be swallowed; that is a real mismatch. (Task 2, `a redundant upload of another build still fails`.)
3. **A missing or empty secret** should stop the job with its name before a ten-minute build, not fail obscurely at export. (Task 2, `a missing secret stops it before any build`.)
4. **The key on disk after a failed upload** must be gone, like after a good one. (Task 2, `the key is gone afterwards, success or not`.)
5. **Someone "fixing" the SSO scheme to match the new bundle id** would break sign-in against Kanidm's registered redirect. (Task 1, `the SSO callback scheme did not follow the bundle id`.)

---

### Task 1: The iOS app's identity

**Files:**
- Create: `test/release/ios_identity_test.dart`
- Modify: `ios/Runner.xcodeproj/project.pbxproj` (six `PRODUCT_BUNDLE_IDENTIFIER` lines)
- Modify: `ios/Runner/Info.plist`

**Interfaces:**
- Consumes: `SheetSsoBrowser.scheme` from `lib/matrix/sso_browser.dart` (exists).
- Produces: the bundle id `moe.loaf.chat.ios`, which Task 2's export signs for and Task 5 uploads under.

- [ ] **Step 1: Write the failing test**

Create `test/release/ios_identity_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/sso_browser.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  final project = _read('ios/Runner.xcodeproj/project.pbxproj');

  test('the iOS app is moe.loaf.chat.ios in every configuration', () {
    final ids = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);')
        .allMatches(project)
        .map((m) => m.group(1))
        .toList();
    expect(ids.where((id) => id == 'moe.loaf.chat.ios'), hasLength(3));
    expect(
      ids.where((id) => id == 'moe.loaf.chat.ios.RunnerTests'),
      hasLength(3),
    );
    expect(ids, hasLength(6));
  });

  test('nothing in the iOS project still names moe.loaf.native', () {
    expect(project, isNot(contains('moe.loaf.native')));
  });

  test('builds declare their encryption, so none waits on compliance', () {
    expect(
      _read('ios/Runner/Info.plist'),
      matches(RegExp(r'<key>ITSAppUsesNonExemptEncryption</key>\s*<false/>')),
    );
  });

  test('the SSO callback scheme did not follow the bundle id', () {
    // Kanidm's redirect is registered against this scheme; it is a fixed
    // string on purpose, not the bundle id.
    expect(SheetSsoBrowser.scheme, 'moe.loaf.native');
  });
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `mise exec -- flutter test test/release/ios_identity_test.dart`
Expected: the first three tests FAIL (bundle ids are `moe.loaf.native`, no `ITSAppUsesNonExemptEncryption`); the scheme test PASSES.

- [ ] **Step 3: Rename the bundle ids**

In `ios/Runner.xcodeproj/project.pbxproj`, replace every
`PRODUCT_BUNDLE_IDENTIFIER = moe.loaf.native;` with
`PRODUCT_BUNDLE_IDENTIFIER = moe.loaf.chat.ios;` (three lines), and every
`PRODUCT_BUNDLE_IDENTIFIER = moe.loaf.native.RunnerTests;` with
`PRODUCT_BUNDLE_IDENTIFIER = moe.loaf.chat.ios.RunnerTests;` (three lines).
Touch nothing else in the file.

- [ ] **Step 4: Declare export compliance**

In `ios/Runner/Info.plist`, directly after the `NSPhotoLibraryUsageDescription` string and before `</dict>`, add:

```xml
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
```

- [ ] **Step 5: Run the tests**

Run: `mise exec -- flutter test test/release/ios_identity_test.dart`
Expected: 4 tests PASS.

Run: `mise exec -- flutter test`
Expected: everything PASSES.

- [ ] **Step 6: The project still builds**

Run: `mise exec -- flutter build ios --debug --no-codesign`
Expected: `✓ Built build/ios/iphoneos/Runner.app`.

- [ ] **Step 7: Commit**

```bash
git add test/release/ios_identity_test.dart ios/Runner.xcodeproj/project.pbxproj ios/Runner/Info.plist
git commit -m "feat(ios): moe.loaf.chat.ios, with export compliance declared" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `ios.sh`, which builds, signs and uploads

**Files:**
- Create: `tool/release/ios.sh` (executable)
- Create: `tool/release/ios-export.plist`
- Create: `test/release/ios_upload_test.dart`

**Interfaces:**
- Consumes: the bundle id from Task 1; `ios/Runner.xcworkspace`, scheme `Runner`.
- Produces: `tool/release/ios.sh <version> <build>`, reading `NOTARY_KEY_P8` (base64), `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` from the environment. Exit 0 means App Store Connect has this build. Task 3's job calls it exactly so.

The test runs the real script with stand-ins for `mise`, `xcodebuild` and `plutil` first on `PATH`, so it runs on Linux too. Each stand-in appends a line to `$CALLS`; the `xcodebuild` stand-in also records the key file's contents, and plays back `$EXPORT_OUTPUT` and `$EXPORT_STATUS` for the export.

- [ ] **Step 1: Write the failing test**

Create `test/release/ios_upload_test.dart`:

```dart
@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _key = 'not really a key';

late Directory _dir;
late Directory _bin;
late Directory _tmp;
late File _calls;

void _stub(String name, String body) {
  final file = File('${_bin.path}/$name')
    ..writeAsStringSync('#!/usr/bin/env bash\n$body\n');
  Process.runSync('chmod', ['+x', file.path]);
}

Future<ProcessResult> _run({
  Map<String, String> env = const {},
  String exportOutput = '** EXPORT SUCCEEDED **',
  int exportStatus = 0,
}) =>
    Process.run(
      'bash',
      ['tool/release/ios.sh', '0.1.0', '42'],
      environment: {
        'PATH': '${_bin.path}:${Platform.environment['PATH']}',
        'TMPDIR': _tmp.path,
        'CALLS': _calls.path,
        'EXPORT_OUTPUT': exportOutput,
        'EXPORT_STATUS': '$exportStatus',
        'NOTARY_KEY_P8': base64.encode(utf8.encode(_key)),
        'NOTARY_KEY_ID': 'KEYID',
        'NOTARY_ISSUER_ID': 'ISSUER',
        ...env,
      },
    );

List<String> _lines() =>
    _calls.existsSync() ? _calls.readAsLinesSync() : const [];

String _redundant(String build) =>
    "ERROR: Redundant Binary Upload. You've already uploaded a build with "
    "build number '$build' for version number '0.1.0'.";

void main() {
  setUp(() {
    _dir = Directory.systemTemp.createTempSync('ios_upload_test');
    _bin = Directory('${_dir.path}/bin')..createSync();
    _tmp = Directory('${_dir.path}/tmp')..createSync();
    _calls = File('${_dir.path}/calls');
    _stub('mise', r'echo "mise $*" >> "$CALLS"');
    _stub('plutil', r'echo "plutil $*" >> "$CALLS"');
    _stub('xcodebuild', r'''
echo "xcodebuild $*" >> "$CALLS"
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = -authenticationKeyPath ]; then
    j=$((i + 1)); echo "key $(cat "${!j}")" >> "$CALLS"
  fi
done
case " $* " in
  *" -exportArchive "*) echo "$EXPORT_OUTPUT"; exit "$EXPORT_STATUS" ;;
esac''');
  });

  tearDown(() => _dir.deleteSync(recursive: true));

  test('a missing secret stops it before any build', () async {
    final result = await _run(env: {'NOTARY_KEY_ID': ''});
    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('::error::NOTARY_KEY_ID'));
    expect(_lines(), isEmpty);
  });

  test('it configures, archives unsigned, then signs and uploads', () async {
    final result = await _run();
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    final lines = _lines();
    final configure = lines.indexWhere((l) => l.startsWith('mise '));
    final archive = lines.indexWhere((l) => l.contains(' archive '));
    final export = lines.indexWhere((l) => l.contains(' -exportArchive '));
    expect([configure, archive, export], everyElement(isNot(-1)));
    expect(configure < archive && archive < export, isTrue);
    expect(
      lines[configure],
      'mise exec -- flutter build ios --release --config-only '
      '--build-name=0.1.0 --build-number=42 --dart-define=LOAF_BUILD=42',
    );
    expect(lines[archive], contains('-workspace ios/Runner.xcworkspace'));
    expect(lines[archive], contains('-scheme Runner'));
    expect(lines[archive], contains('CODE_SIGNING_ALLOWED=NO'));
    expect(
      lines[export],
      allOf(
        contains('-exportOptionsPlist tool/release/ios-export.plist'),
        contains('-allowProvisioningUpdates'),
        contains('-authenticationKeyID KEYID'),
        contains('-authenticationKeyIssuerID ISSUER'),
      ),
    );
    expect(lines, contains('key $_key'));
    expect(lines, contains('plutil -lint tool/release/ios-export.plist'));
  });

  test('the key is gone afterwards, success or not', () async {
    await _run();
    expect(_tmp.listSync(), isEmpty);
    await _run(exportOutput: 'error: upload failed', exportStatus: 70);
    expect(_tmp.listSync(), isEmpty);
  });

  test('a build already on TestFlight is not a failure', () async {
    final result =
        await _run(exportOutput: _redundant('42'), exportStatus: 70);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('::notice::'));
  });

  test('a redundant upload of another build still fails', () async {
    final result =
        await _run(exportOutput: _redundant('41'), exportStatus: 70);
    expect(result.exitCode, isNot(0));
  });

  test("any other upload failure fails, with Apple's message", () async {
    final result = await _run(
      exportOutput: 'error: Cloud signing permission error',
      exportStatus: 70,
    );
    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('Cloud signing permission error'));
    expect(result.stdout, contains('::error::'));
  });

  test('the export options sign for the App Store and upload', () {
    final plist = File('tool/release/ios-export.plist').readAsStringSync();
    String? value(String key) => RegExp(
          '<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>',
        ).firstMatch(plist)?.group(1);
    expect(value('method'), 'app-store-connect');
    expect(value('destination'), 'upload');
    expect(value('signingStyle'), 'automatic');
    expect(value('teamID'), '6W2A5N37N3');
  });
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `mise exec -- flutter test test/release/ios_upload_test.dart`
Expected: every test FAILS (no `tool/release/ios.sh`, no `ios-export.plist`).

- [ ] **Step 3: The export options**

Create `tool/release/ios-export.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>6W2A5N37N3</string>
</dict>
</plist>
```

- [ ] **Step 4: The script**

Create `tool/release/ios.sh`, then `chmod +x tool/release/ios.sh`:

```bash
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
```

- [ ] **Step 5: Run the tests**

Run: `mise exec -- flutter test test/release/ios_upload_test.dart`
Expected: 7 tests PASS.

Run: `mise exec -- flutter test`
Expected: everything PASSES.

- [ ] **Step 6: Commit**

```bash
git add tool/release/ios.sh tool/release/ios-export.plist test/release/ios_upload_test.dart
git commit -m "feat(release): ios.sh archives, cloud-signs and uploads to TestFlight" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The `ios` job, and the README

**Files:**
- Create: `test/release/release_workflow_test.dart`
- Modify: `.github/workflows/release.yml` (a new job between `macos` and `linux`)
- Modify: `README.md` (the Releasing section)

**Interfaces:**
- Consumes: `tool/release/ios.sh <version> <build>` from Task 2; `needs.version.outputs.name` and `.build` (exist).
- Produces: the `ios` job Task 5 rehearses.

- [ ] **Step 1: Write the failing test**

Create `test/release/release_workflow_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _jobs = File('.github/workflows/release.yml')
    .readAsStringSync()
    .split('\njobs:\n')
    .last;

/// One job's block: from its name to the next job's.
String _job(String name) {
  final start = _jobs.indexOf(RegExp('^  $name:\$', multiLine: true));
  expect(start, isNot(-1), reason: 'no $name job');
  final rest = _jobs.substring(start);
  final next = RegExp(r'^  [a-z][a-z-]*:$', multiLine: true)
      .allMatches(rest)
      .skip(1)
      .firstOrNull;
  return next == null ? rest : rest.substring(0, next.start);
}

void main() {
  test('the ios job runs ios.sh with the release version and key', () {
    final ios = _job('ios');
    expect(ios, contains('needs: version'));
    expect(ios, contains('runs-on: macos-latest'));
    expect(ios, contains('environment: release'));
    expect(ios, contains('tool/release/ios.sh'));
    expect(ios, contains(r'${{ needs.version.outputs.name }}'));
    expect(ios, contains(r'${{ needs.version.outputs.build }}'));
    for (final secret in ['NOTARY_KEY_P8', 'NOTARY_KEY_ID', 'NOTARY_ISSUER_ID']) {
      expect(ios, contains('$secret: \${{ secrets.$secret }}'));
    }
  });

  test('publish never waits on iOS', () {
    final needs = RegExp(r'needs: \[([^\]]*)\]').firstMatch(_job('publish'));
    expect(needs, isNotNull);
    expect(needs!.group(1), isNot(contains('ios')));
  });
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `mise exec -- flutter test test/release/release_workflow_test.dart`
Expected: `the ios job …` FAILS with "no ios job"; `publish never waits on iOS` PASSES.

- [ ] **Step 3: The job**

In `.github/workflows/release.yml`, after the `macos` job's last line (`path: dist/` under its upload step) and before `  linux:`, add:

```yaml

  # Straight to TestFlight; nothing iOS goes in the GitHub Release. publish
  # does not need this job, so a slow App Store Connect never holds back the
  # desktop release.
  ios:
    needs: version
    runs-on: macos-latest
    environment: release
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2
      - run: >
          tool/release/ios.sh "${{ needs.version.outputs.name }}"
          "${{ needs.version.outputs.build }}"
        env:
          # One App Store Connect API key notarizes macOS and, through cloud
          # signing, signs and uploads iOS. The names predate iOS.
          NOTARY_KEY_P8: ${{ secrets.NOTARY_KEY_P8 }}
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER_ID: ${{ secrets.NOTARY_ISSUER_ID }}
```

Leave `publish`'s `needs: [version, macos, linux, flatpak]` as it is.

- [ ] **Step 4: The README**

In `README.md`, in the Releasing section, replace:

```markdown
does the rest: it builds, signs and notarizes, publishes a GitHub Release, and
rewrites get.loaf.moe, including the download page in `tool/release/site/`.
```

with:

```markdown
does the rest: it builds, signs and notarizes, publishes a GitHub Release, and
rewrites get.loaf.moe, including the download page in `tool/release/site/`.
The same tag sends iOS to TestFlight, where the Testing group picks it up.
```

The Installing section's "Phones get Loaf Chat through TestFlight." stays.

- [ ] **Step 5: Run the tests**

Run: `mise exec -- flutter test test/release/`
Expected: every test in the three files PASSES.

Run: `mise exec -- flutter test`
Expected: everything PASSES.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/release.yml README.md test/release/release_workflow_test.dart
git commit -m "feat(release): every tag sends iOS to TestFlight" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: App Store Connect settings (Chris)

**This task changes account settings. An agent stops here and hands over.**

- [ ] **Step 1: The key's role**

App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys. Find the key whose ID is in `NOTARY_KEY_ID`. Its access must be **Admin**: cloud-managed distribution certificates need it. The desktop-updates plan created this key with the **Developer** role, so expect to raise it. If App Store Connect will not change a key's role, create an Admin key and replace all three `NOTARY_*` secrets with it, in Nushell:

```bash
open --raw AuthKey.p8 | encode base64 | gh secret set NOTARY_KEY_P8 --env release
```

```bash
gh secret set NOTARY_KEY_ID --env release
```

```bash
gh secret set NOTARY_ISSUER_ID --env release
```

Then revoke the old key.

- [ ] **Step 2: Testers**

App Store Connect › Apps › the `moe.loaf.chat.ios` app › TestFlight › Testing. Add the internal testers; each installs the TestFlight app on their iPhone.

- [ ] **Step 3: Automatic distribution — after Task 5's local run**

In the Testing group, turn on **automatic distribution**. Do this after Task 5 step 1, so the rehearsal's throwaway build does not reach testers.

---

### Task 5: The rehearsal (Chris)

**Files:**
- Modify: `docs/superpowers/specs/2026-09-30-ios-testflight-design.md` (record what the rehearsal found, under Findings)

The rehearsal is the spec's acceptance test. It uploads real builds.

- [ ] **Step 1: Locally, before any tag**

On the Mac, from the repo root, in Nushell, with the key's `.p8` at hand. Version `0.0.1` build `1` is never tagged and is below every real build number, so it cannot collide with a release.

```bash
with-env { NOTARY_KEY_P8: (open --raw AuthKey.p8 | encode base64), NOTARY_KEY_ID: "<key id>", NOTARY_ISSUER_ID: "<issuer id>" } { bash tool/release/ios.sh 0.0.1 1 }
```

Expected: the export ends `** EXPORT SUCCEEDED **` and the script exits 0. Within about 30 minutes, build `0.0.1 (1)` is in App Store Connect › TestFlight with no Missing Compliance flag.

If export fails:
- **A cloud signing permission error:** the key is not Admin; back to Task 4 step 1.
- **It refuses to sign the unsigned archive:** stop. Fall back to the spec's alternative (sign at archive with the cloud-managed distribution identity), which needs its own change and test.

Then do Task 4 step 3.

- [ ] **Step 2: Run it again, unchanged**

The same command once more. Expected: exit 0 with `::notice::build <n> is already on TestFlight`. If it fails instead, copy Apple's exact redundant-upload wording into the spec and into `ios.sh`'s `grep` and the test's `_redundant`, and commit that before tagging.

- [ ] **Step 3: A real tag**

Tag the next version on `main` and push it. Expected: `ios` goes green; `publish` finishes without waiting on it.

- [ ] **Step 4: On a phone**

Within about 30 minutes the build is **Ready to Test** in Testing, and appears in TestFlight on a tester's iPhone without anyone adding it. Sign in on it once: SSO through Kanidm still completes.

- [ ] **Step 5: Re-run all jobs**

In GitHub Actions, "Re-run all jobs" on that tag's run. Expected: `ios` passes with the `::notice::`.

- [ ] **Step 6: Apple's email**

Check the processing email for the tag's build. Expected: no `ITMS-91053` (missing privacy manifest declarations) or `ITMS-90683` (missing usage strings). If either appears, the fix joins this work: add `ios/Runner/PrivacyInfo.xcprivacy` or the named usage strings, with a test in `test/release/ios_identity_test.dart`, and tag again.

- [ ] **Step 7: Record and commit**

Under the spec's Findings, move each "Not verified" item to verified, or note what changed.

```bash
git add docs/superpowers/specs/2026-09-30-ios-testflight-design.md
git commit -m "docs(ios): what the TestFlight rehearsal found" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
