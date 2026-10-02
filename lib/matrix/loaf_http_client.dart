/// The HTTP client the SDK sends through. A dead network has to say "didn't
/// send" within about 30 s, and the SDK's own limit covers response bodies
/// only, so this adds the two it lacks: how long the server may take to
/// answer, and how long an upload may go without moving.
library;

import 'dart:async';

import 'package:http/http.dart' as http;

/// [sent] bytes of [total] (null when the length is unknown) have gone.
typedef UploadProgress = void Function(int sent, int? total);

const _chunk = 64 * 1024;
final _progressKey = Object();

class LoafHttpClient extends http.BaseClient {
  LoafHttpClient(
    this._inner, {
    this.headersWithin = const Duration(seconds: 20),
    this.uploadIdle = const Duration(seconds: 30),
  });

  final http.Client _inner;

  /// How long a server may take to start answering once the request is
  /// sent.
  final Duration headersWithin;

  /// How long an upload may go without a chunk leaving.
  final Duration uploadIdle;

  /// Runs [body] so that any media upload it starts reports to [onProgress].
  /// Zone values carry the callback through the SDK's awaits to [send],
  /// which is how an upload knows whose it is.
  static R reportingUploads<R>(UploadProgress onProgress, R Function() body) =>
      runZoned(body, zoneValues: {_progressKey: onProgress});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // /sync long-polls for up to 30 s by design; the SDK's own body idle
    // limit covers it once headers arrive.
    if (request.url.path.endsWith('/sync')) return _inner.send(request);
    final upload =
        request.method == 'POST' &&
        request.url.path.contains('/media/') &&
        request.url.path.endsWith('/upload');
    final abort = Completer<void>();
    Timer? timer;
    void arm(Duration within) {
      timer?.cancel();
      timer = Timer(within, () {
        if (!abort.isCompleted) abort.complete();
      });
    }

    final progress = upload
        ? Zone.current[_progressKey] as UploadProgress?
        : null;
    final total = request.contentLength;
    var body = request.finalize();
    if (upload) {
      body = http.ByteStream(
        _chunked(
          body,
          (sent) {
            progress?.call(sent, total);
            arm(uploadIdle);
          },
          // The body is all out: now it is the server's turn.
          onDone: () => arm(headersWithin),
        ),
      );
    }
    final copy = _Copy(request, body, abort.future);
    arm(upload ? uploadIdle : headersWithin);
    try {
      return await _inner.send(copy);
    } finally {
      timer?.cancel();
    }
  }

  @override
  void close() => _inner.close();
}

/// [source] re-sliced into [_chunk]-sized pieces. The generator is paused at
/// each `yield` until the socket takes the piece, so [onSent] counts what
/// has actually gone rather than what was buffered.
Stream<List<int>> _chunked(
  Stream<List<int>> source,
  void Function(int sent) onSent, {
  required void Function() onDone,
}) async* {
  var sent = 0;
  await for (final list in source) {
    for (var i = 0; i < list.length; i += _chunk) {
      final end = i + _chunk < list.length ? i + _chunk : list.length;
      yield list.sublist(i, end);
      sent += end - i;
      onSent(sent);
    }
  }
  onDone();
}

/// [original] with [body] in place of its own and [abortTrigger] attached:
/// a finalized request can't be given either.
class _Copy extends http.BaseRequest with http.Abortable {
  _Copy(http.BaseRequest original, this._body, this.abortTrigger)
    : super(original.method, original.url) {
    headers.addAll(original.headers);
    contentLength = original.contentLength;
    followRedirects = original.followRedirects;
    maxRedirects = original.maxRedirects;
    persistentConnection = original.persistentConnection;
  }

  final http.ByteStream _body;

  @override
  final Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return _body;
  }
}
