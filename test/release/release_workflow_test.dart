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
  final next = RegExp(
    r'^  [a-z][a-z-]*:$',
    multiLine: true,
  ).allMatches(rest).skip(1).firstOrNull;
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
    for (final secret in [
      'NOTARY_KEY_P8',
      'NOTARY_KEY_ID',
      'NOTARY_ISSUER_ID',
    ]) {
      expect(ios, contains('$secret: \${{ secrets.$secret }}'));
    }
  });

  test('publish never waits on iOS', () {
    final needs = RegExp(r'needs: \[([^\]]*)\]').firstMatch(_job('publish'));
    expect(needs, isNotNull);
    expect(needs!.group(1), isNot(contains('ios')));
  });
}
