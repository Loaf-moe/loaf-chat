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
}) => Process.run(
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
    expect(lines, contains('plutil -lint tool/release/ios-export.plist'));
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
}
