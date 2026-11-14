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

/// What a correctly signed build carries. A test drops one piece to prove
/// the gate stops it.
const _goodApp =
    '{"aps-environment":"production",'
    '"com.apple.security.application-groups":["group.moe.loaf.chat"]}';
const _goodAppex =
    '{"com.apple.security.application-groups":["group.moe.loaf.chat"],'
    '"com.apple.developer.usernotifications.filtering":true}';

Future<ProcessResult> _run({
  Map<String, String> env = const {},
  String appEntitlements = _goodApp,
  String appexEntitlements = _goodAppex,
  String exportOutput = '** EXPORT SUCCEEDED **',
  int exportStatus = 0,
}) => Process.run(
  'bash',
  ['tool/release/ios.sh', '0.1.0', '42'],
  environment: {
    'PATH': '${_bin.path}:${Platform.environment['PATH']}',
    'TMPDIR': _tmp.path,
    'CALLS': _calls.path,
    'EXPORT_OUTPUT': exportOutput,
    'EXPORT_STATUS': '$exportStatus',
    'APP_ENTS': appEntitlements,
    'APPEX_ENTS': appexEntitlements,
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
    // plutil both lints and, in the gate, converts the entitlements the
    // codesign stub prints; -convert has to pass stdin through.
    _stub('plutil', r'''
echo "plutil $*" >> "$CALLS"
case " $* " in
  *" -convert "*) cat ;;
esac''');
    // The gate reads the signed app out of the exported ipa.
    _stub('unzip', r'''
echo "unzip $*" >> "$CALLS"
app="$4/Payload/Runner.app"
mkdir -p "$app/PlugIns/NotifyService.appex"
[ "${NO_FRAMEWORK:-}" = 1 ] || mkdir -p "$app/Frameworks/loaf_push.framework"
[ "${NO_CHIME:-}" = 1 ] || : > "$app/chime.caf"''');
    // Signing calls are logged; reading entitlements answers from the env.
    _stub('codesign', r'''
case " $* " in
  *" -s "*) echo "codesign $*" >> "$CALLS"; exit 0 ;;
esac
case "$*" in
  *NotifyService.appex*) echo "$APPEX_ENTS" ;;
  *) echo "$APP_ENTS" ;;
esac''');
    _stub('xcodebuild', r'''
echo "xcodebuild $*" >> "$CALLS"
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = -authenticationKeyPath ]; then
    j=$((i + 1)); echo "key $(cat "${!j}")" >> "$CALLS"
  fi
done
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = -exportPath ]; then
    j=$((i + 1)); mkdir -p "${!j}"; : > "${!j}/Runner.ipa"
  fi
done
case " $* " in
  # Only the upload export answers with Apple's message; the gate's local
  # export always succeeds unless a test says otherwise.
  *"ios-export.plist"*) echo "$EXPORT_OUTPUT"; exit "$EXPORT_STATUS" ;;
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
    // Two exports now: the gate's local one, then the upload.
    final exports = [
      for (var i = 0; i < lines.length; i++)
        if (lines[i].contains(' -exportArchive ')) i,
    ];
    expect(exports, hasLength(2));
    final check = exports.first;
    final export = exports.last;
    expect(lines[check], contains('ios-export-local.plist'));
    expect([configure, archive], everyElement(isNot(-1)));
    expect(configure < archive && archive < check, isTrue);
    expect(
      lines[configure],
      'mise exec -- flutter build ios --release --config-only '
      '--build-name=0.1.0 --build-number=42 --dart-define=LOAF_BUILD=42 --dart-define=LOAF_VERSION=0.1.0',
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
    expect(
      lines,
      contains(
        'plutil -lint tool/release/ios-export.plist '
        'tool/release/ios-export-local.plist',
      ),
    );
  });

  test('the archive carries the entitlements the export signs in', () async {
    // Export takes each binary's entitlements from its existing signature,
    // and an unsigned archive has none: v0.1.27 exported without the App
    // Group. An ad-hoc signature carries them without minting a certificate.
    final result = await _run();
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    final lines = _lines();
    final archive = lines.indexWhere((l) => l.contains(' archive '));
    final check = lines.indexWhere((l) => l.contains(' -exportArchive '));
    final appex = lines.indexWhere(
      (l) =>
          l.startsWith('codesign ') &&
          l.contains(
            '--entitlements ios/NotifyService/NotifyService.entitlements',
          ),
    );
    final app = lines.indexWhere(
      (l) =>
          l.startsWith('codesign ') &&
          l.contains('--entitlements ios/Runner/Runner.entitlements'),
    );
    expect([archive, appex, app, check], everyElement(isNot(-1)));
    // Inside out: signing the app seals the extension's signature into it.
    expect(archive < appex && appex < app && app < check, isTrue);
    expect(lines[appex], contains(' -s - '));
    expect(
      lines[appex],
      endsWith(
        'Runner.xcarchive/Products/Applications/Runner.app/PlugIns/NotifyService.appex',
      ),
    );
    expect(lines[app], contains(' -s - '));
    expect(
      lines[app],
      endsWith('Runner.xcarchive/Products/Applications/Runner.app'),
    );
  });

  test('the key is gone afterwards, success or not', () async {
    await _run();
    // The key reached the export, so it was on disk under TMPDIR.
    expect(_lines(), contains('key $_key'));
    expect(_tmp.listSync(), isEmpty);
    _calls.deleteSync();
    await _run(exportOutput: 'error: upload failed', exportStatus: 70);
    expect(_lines(), contains('key $_key'));
    expect(_tmp.listSync(), isEmpty);
  });

  test('a build already on TestFlight is not a failure', () async {
    final result = await _run(exportOutput: _redundant('42'), exportStatus: 70);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('::notice::'));
  });

  test('a redundant upload of another build still fails', () async {
    final result = await _run(exportOutput: _redundant('41'), exportStatus: 70);
    expect(result.exitCode, isNot(0));
    expect(result.stdout, contains('::error::'));
    expect(result.stdout, isNot(contains('::notice::')));
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
    String? value(String key) =>
        RegExp('<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>')
            .firstMatch(plist)
            ?.group(1);
    expect(value('method'), 'app-store-connect');
    expect(value('destination'), 'upload');
    expect(value('signingStyle'), 'automatic');
    expect(value('teamID'), '6W2A5N37N3');
  });
  group('the entitlement gate', () {
    // Nothing before this proves the signed build carries push: the archive
    // is unsigned and the export is what signs it. A build that reaches
    // Apple without these is a build whose notifications never work.
    Future<void> stops(ProcessResult result, String message) async {
      expect(result.exitCode, isNot(0), reason: '${result.stdout}');
      expect(result.stdout, contains('::error::'));
      expect(result.stdout, contains(message));
      // And it never got as far as uploading.
      expect(_lines().where((l) => l.contains(' ios-export.plist ')), isEmpty);
    }

    test('an app without the App Group never reaches Apple', () async {
      await stops(
        await _run(appEntitlements: '{"aps-environment":"production"}'),
        'Runner.app lacks the App Group',
      );
    });

    test('an extension without the App Group never reaches Apple', () async {
      await stops(
        await _run(
          appexEntitlements:
              '{"com.apple.developer.usernotifications.filtering":true}',
        ),
        'NotifyService.appex lacks the App Group',
      );
    });

    test('a sandbox build never reaches Apple', () async {
      await stops(
        await _run(
          appEntitlements:
              '{"aps-environment":"development",'
              '"com.apple.security.application-groups":'
              '["group.moe.loaf.chat"]}',
        ),
        'aps-environment=production',
      );
    });

    test('an extension that cannot suppress never reaches Apple', () async {
      // Without filtering, delivering empty content shows a blank alert
      // instead of nothing: every dropped push becomes a notification.
      await stops(
        await _run(
          appexEntitlements:
              '{"com.apple.security.application-groups":'
              '["group.moe.loaf.chat"]}',
        ),
        'lacks the filtering entitlement',
      );
    });

    test('a build without loaf_push never reaches Apple', () async {
      await stops(
        await _run(env: {'NO_FRAMEWORK': '1'}),
        'loaf_push is not in the app',
      );
    });

    test('a build without the chime never reaches Apple', () async {
      // UNNotificationSound names chime.caf and resolves it against the
      // app bundle; without it a push plays iOS's default sound.
      await stops(
        await _run(env: {'NO_CHIME': '1'}),
        'chime.caf is not in the app bundle',
      );
    });
  });

  test('the gate exports locally, signing the same way', () {
    final plist = File('tool/release/ios-export-local.plist')
        .readAsStringSync();
    String? value(String key) =>
        RegExp('<key>${RegExp.escape(key)}</key>\\s*<string>([^<]*)</string>')
            .firstMatch(plist)
            ?.group(1);
    expect(value('method'), 'app-store-connect');
    // The one difference from the upload plist: it stops at a folder.
    expect(value('destination'), 'export');
    expect(value('signingStyle'), 'automatic');
    expect(value('teamID'), '6W2A5N37N3');
  });
}
