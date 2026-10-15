import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loaf_native/util/http_download.dart';
import 'package:path/path.dart' as p;

final _url = Uri.parse('https://example.com/build.zip');
final _bytes = List.generate(1000, (i) => i % 256);
final _hash = '${crypto.sha256.convert(_bytes)}';

http.Client _serving(List<int> body, {int status = 200}) =>
    MockClient((_) async => http.Response.bytes(body, status));

void main() {
  late Directory dir;
  late File to;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('download_test');
    to = File(p.join(dir.path, 'build.zip'));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<File> fetch(http.Client client, {String? sha256, int? size}) =>
      download(
        client,
        _url,
        to,
        size: size ?? _bytes.length,
        sha256: sha256 ?? _hash,
        idleTimeout: const Duration(seconds: 5),
      );

  test('a verified download lands whole, with nothing beside it', () async {
    final file = await fetch(_serving(_bytes));
    expect(file.path, to.path);
    expect(file.readAsBytesSync(), _bytes);
    expect(dir.listSync(), hasLength(1));
  });

  for (final (name, client, sha, size) in [
    ('a failed answer', _serving(_bytes, status: 404), null, null),
    ('a wrong hash', _serving(_bytes), 'beef', null),
    ('too few bytes', _serving(_bytes.sublist(1)), null, null),
    ('too many bytes', _serving([..._bytes, 0]), null, null),
    ('a Content-Length other than the size', _serving(_bytes), null, 999),
  ]) {
    test('$name leaves nothing behind', () async {
      await expectLater(
        fetch(client, sha256: sha, size: size),
        throwsA(isA<HttpException>()),
      );
      expect(dir.listSync(), isEmpty);
    });
  }

  test('silence past the idle timeout gives up and leaves nothing', () async {
    final stalled = MockClient.streaming(
      (_, _) async =>
          http.StreamedResponse(StreamController<List<int>>().stream, 200),
    );
    await expectLater(
      download(
        stalled,
        _url,
        to,
        size: 10,
        sha256: _hash,
        idleTimeout: const Duration(milliseconds: 50),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(dir.listSync(), isEmpty);
  });
}
