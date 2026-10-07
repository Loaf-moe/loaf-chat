import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loaf_native/update/release_feed.dart';

const _feed = '''
{"version":"0.1.1","build":412,"appimage":{
  "url":"https://github.com/Loaf-moe/loaf-chat/releases/download/v0.1.1/Loaf-Chat-0.1.1-x86_64.AppImage",
  "sha256":"abc123","size":1024,"signature":"c2ln"},
 "windows":{
  "url":"https://github.com/Loaf-moe/loaf-chat/releases/download/v0.1.1/Loaf-Chat-0.1.1-windows-x64.zip",
  "sha256":"def456","size":2048,"signature":"d2lu"}}
''';

void main() {
  test('a feed parses', () {
    final release = Release.parse(_feed);
    expect(release.version, '0.1.1');
    expect(release.build, 412);
    expect(release.appImage!.size, 1024);
    expect(release.appImage!.url.host, 'github.com');
  });

  test('the signed text names the version, the build and the hash', () {
    expect(
      Release.parse(_feed).signedTextFor(AssetKind.appImage),
      'loaf-chat-appimage\n0.1.1\n412\nabc123',
    );
  });

  test('each asset signs its own text, so one never passes for another', () {
    final release = Release.parse(_feed);
    expect(release.windows!.size, 2048);
    expect(
      release.signedTextFor(AssetKind.windows),
      'loaf-chat-windows\n0.1.1\n412\ndef456',
    );
  });

  test('a feed from before Windows still parses', () {
    final release = Release.parse(
      '{"version":"0.1.1","build":412,"appimage":'
      '{"url":"https://x/a","sha256":"abc","size":1,"signature":"s"}}',
    );
    expect(release.appImage, isNotNull);
    expect(release.windows, isNull);
  });

  test('a feed with no AppImage still says its version', () {
    final release = Release.parse('{"version":"0.1.1","build":412}');
    expect(release.appImage, isNull);
    expect(release.windows, isNull);
  });

  for (final (name, body) in [
    ('a web page', '<html><body>sign in to the wifi</body></html>'),
    ('a list', '[1, 2, 3]'),
    ('no build', '{"version":"0.1.1"}'),
    ('a build that is a string', '{"version":"0.1.1","build":"412"}'),
    ('nothing', ''),
  ]) {
    test('$name is not a feed', () {
      expect(() => Release.parse(body), throwsFormatException);
    });
  }

  test('fetching refuses anything but a 200', () async {
    final client = MockClient((_) async => http.Response('gone', 404));
    await expectLater(
      fetchRelease(client, Uri.parse('https://get.loaf.moe/latest.json')),
      throwsA(isA<Exception>()),
    );
  });

  test('fetching returns the release', () async {
    final client = MockClient((_) async => http.Response(_feed, 200));
    final release = await fetchRelease(
      client,
      Uri.parse('https://get.loaf.moe/latest.json'),
    );
    expect(release.build, 412);
  });
}
