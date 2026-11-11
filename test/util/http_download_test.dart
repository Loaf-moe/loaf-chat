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

/// A server whose Content-Length always matches what it sends, the way
/// [MockClient] fills it in from the body.
http.Client _serving(List<int> body, {int status = 200}) =>
    MockClient((_) async => http.Response.bytes(body, status));

/// A server that sends [body] while claiming [contentLength] bytes: null for
/// a chunked answer, the wrong number for one whose header cannot be
/// trusted. Only this shape reaches the checks on the bytes themselves.
http.Client _streaming(List<int> body, {int? contentLength}) =>
    MockClient.streaming(
      (_, _) async => http.StreamedResponse(
        Stream.value(body),
        200,
        contentLength: contentLength,
      ),
    );

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

  // The message pins each case to the check that refused it: three of these
  // used to stop at Content-Length, leaving the checks on the bytes
  // themselves unrun.
  for (final (name, client, sha, size, refusal) in [
    ('a failed answer', _serving(_bytes, status: 404), null, null, '404'),
    ('a wrong hash', _serving(_bytes), 'beef', null, 'the hash does not match'),
    (
      'a Content-Length other than the size',
      _serving(_bytes),
      null,
      999,
      'Content-Length 1000, not 999',
    ),
    (
      'too few bytes, chunked',
      _streaming(_bytes.sublist(1)),
      null,
      null,
      '999 bytes, not 1000',
    ),
    (
      'too many bytes, chunked',
      _streaming([..._bytes, 0]),
      null,
      null,
      'more than 1000 bytes',
    ),
    (
      'too few bytes behind a Content-Length that looks right',
      _streaming(_bytes.sublist(1), contentLength: 1000),
      null,
      null,
      '999 bytes, not 1000',
    ),
    (
      'too many bytes behind a Content-Length that looks right',
      _streaming([..._bytes, 0], contentLength: 1000),
      null,
      null,
      'more than 1000 bytes',
    ),
  ]) {
    test('$name leaves nothing behind', () async {
      await expectLater(
        fetch(client, sha256: sha, size: size),
        throwsA(
          isA<HttpException>().having((e) => e.message, 'message', refusal),
        ),
      );
      expect(dir.listSync(), isEmpty);
    });
  }

  for (final (name, status, contentLength) in [
    ('a failed answer', 404, null),
    ('a Content-Length other than the size', 200, 999),
  ]) {
    test('$name lets go of the answer it refused', () async {
      var released = false;
      final body = StreamController<List<int>>(onCancel: () => released = true);
      final client = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          body.stream,
          status,
          contentLength: contentLength,
        ),
      );
      await expectLater(fetch(client), throwsA(isA<HttpException>()));
      expect(released, isTrue);
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

  test('an answer that arrives after the timeout is let go of', () async {
    var released = false;
    final body = StreamController<List<int>>(onCancel: () => released = true);
    final arriving = Completer<http.StreamedResponse>();
    final slow = MockClient.streaming((_, _) => arriving.future);
    await expectLater(
      download(
        slow,
        _url,
        to,
        size: 10,
        sha256: _hash,
        idleTimeout: const Duration(milliseconds: 50),
      ),
      throwsA(isA<TimeoutException>()),
    );
    arriving.complete(http.StreamedResponse(body.stream, 200));
    await pumpEventQueue();
    expect(released, isTrue);
    expect(dir.listSync(), isEmpty);
  });
}
