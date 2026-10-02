import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/loaf_http_client.dart';

/// Holds each response on a completer, and reads an upload's body only as
/// far as [readChunks] lets it. Aborts like a real client: [send] fails with
/// [http.RequestAbortedException] when the request's trigger fires.
class _Inner extends http.BaseClient {
  final seen = <http.BaseRequest>[];
  final aborted = <http.BaseRequest>[];
  final responses = <Completer<http.StreamedResponse>>[];
  StreamSubscription<List<int>>? body;
  int? stopAfter;
  var chunksRead = 0;

  /// Called per chunk read from the body, with the count so far.
  void Function(int)? onChunk;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    seen.add(request);
    final done = Completer<http.StreamedResponse>();
    responses.add(done);
    if (request is http.Abortable) {
      request.abortTrigger?.then((_) {
        aborted.add(request);
        if (!done.isCompleted) {
          done.completeError(http.RequestAbortedException(request.url));
        }
      });
    }
    final stream = request.finalize();
    chunksRead = 0;
    body = stream.listen((_) {
      chunksRead++;
      onChunk?.call(chunksRead);
      if (stopAfter != null && chunksRead >= stopAfter!) body?.pause();
    }, onError: (Object _) {});
    return done.future;
  }

  void respond([int i = 0]) => responses[i].complete(
    http.StreamedResponse(Stream.value([1, 2, 3]), 200),
  );
}

http.Request _get(String path) =>
    http.Request('GET', Uri.parse('https://hs.example$path'));

http.Request _upload(int bytes) =>
    http.Request('POST', Uri.https('hs.example', '/_matrix/media/v3/upload'))
      ..bodyBytes = Uint8List(bytes);

void main() {
  const chunk = 65536;

  test('a request with no headers in 20 s is aborted', () {
    fakeAsync((async) {
      final inner = _Inner();
      Object? error;
      LoafHttpClient(inner)
          .send(_get('/_matrix/client/v3/account/whoami'))
          .then<void>((_) {}, onError: (Object e) => error = e);
      async.elapse(const Duration(seconds: 19));
      expect(inner.aborted, isEmpty);
      async.elapse(const Duration(seconds: 2));
      expect(inner.aborted, hasLength(1));
      expect(error, isA<http.RequestAbortedException>());
    });
  });

  test('headers in time are not aborted', () {
    fakeAsync((async) {
      final inner = _Inner();
      http.StreamedResponse? response;
      LoafHttpClient(inner)
          .send(_get('/_matrix/client/v3/account/whoami'))
          .then((r) => response = r);
      async.elapse(const Duration(seconds: 19));
      inner.respond();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 60));
      expect(inner.aborted, isEmpty);
      expect(response, isNotNull);
      var bytes = <int>[];
      response!.stream.listen(bytes.addAll);
      async.flushMicrotasks();
      expect(bytes, [1, 2, 3]);
    });
  });

  test('sync is never limited', () {
    fakeAsync((async) {
      final inner = _Inner();
      LoafHttpClient(inner).send(_get('/_matrix/client/v3/sync?timeout=30000'));
      async.elapse(const Duration(seconds: 120));
      expect(inner.seen, hasLength(1));
      expect(inner.aborted, isEmpty);
    });
  });

  test('an upload goes in 64 KB chunks and reports each', () {
    fakeAsync((async) {
      final inner = _Inner();
      final progress = <(int, int?)>[];
      LoafHttpClient.reportingUploads(
        (sent, total) => progress.add((sent, total)),
        () => LoafHttpClient(inner).send(_upload(200 * 1024)),
      );
      async.flushMicrotasks();
      expect(progress, [
        (chunk, 204800),
        (chunk * 2, 204800),
        (chunk * 3, 204800),
        (204800, 204800),
      ]);
      expect(inner.chunksRead, 4);
    });
  });

  test('a stalled upload aborts after 30 s with no progress', () {
    fakeAsync((async) {
      final inner = _Inner()..stopAfter = 2;
      Object? error;
      LoafHttpClient(inner)
          .send(_upload(200 * 1024))
          .then<void>((_) {}, onError: (Object e) => error = e);
      async.elapse(const Duration(seconds: 29));
      expect(inner.chunksRead, 2);
      expect(inner.aborted, isEmpty);
      async.elapse(const Duration(seconds: 2));
      expect(inner.aborted, hasLength(1));
      expect(error, isA<http.RequestAbortedException>());
    });
  });

  test('a slow but moving upload is never cut off', () {
    fakeAsync((async) {
      final inner = _Inner()..stopAfter = 1;
      LoafHttpClient(inner).send(_upload(10 * chunk));
      for (var i = 1; i < 10; i++) {
        async.elapse(const Duration(seconds: 25));
        expect(inner.aborted, isEmpty);
        inner.chunksRead = 0;
        inner.body?.resume();
        async.flushMicrotasks();
      }
      expect(inner.aborted, isEmpty);
    });
  });

  test('uploads outside reportingUploads report nothing, and do not throw', () {
    fakeAsync((async) {
      final inner = _Inner();
      Object? error;
      LoafHttpClient(inner)
          .send(_upload(200 * 1024))
          .then<void>((_) {}, onError: (Object e) => error = e);
      async.flushMicrotasks();
      expect(inner.chunksRead, 4);
      expect(error, isNull);
    });
  });

  test('a body sent, then 20 s without headers, aborts', () {
    fakeAsync((async) {
      final inner = _Inner();
      LoafHttpClient(inner)
          .send(_upload(200 * 1024))
          .then<void>((_) {}, onError: (Object _) {});
      async.flushMicrotasks();
      expect(inner.chunksRead, 4);
      async.elapse(const Duration(seconds: 19));
      expect(inner.aborted, isEmpty);
      async.elapse(const Duration(seconds: 2));
      expect(inner.aborted, hasLength(1));
    });
  });

  test('an upload answered before its body is read is not aborted later', () {
    fakeAsync((async) {
      final inner = _Inner()..stopAfter = 1;
      LoafHttpClient(inner).send(_upload(3 * chunk));
      async.flushMicrotasks();
      inner.respond();
      async.flushMicrotasks();
      // The server said 413 early; the body drains afterwards.
      inner.stopAfter = null;
      inner.body?.resume();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 60));
      expect(inner.aborted, isEmpty);
    });
  });
}
