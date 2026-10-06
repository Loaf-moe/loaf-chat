/// The HTTP client the SDK sends through. A dead network has to say "didn't
/// send" within about 30 s, and the SDK's own limit covers response bodies
/// only, so this adds the two it lacks: how long the server may take to
/// answer, and how long an upload may go without moving.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' show MatrixError, MatrixException;

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
    // The body may still be draining after the server has answered (a 413,
    // say); a timer armed then would abort a request already answered.
    var done = false;
    void arm(Duration within) {
      if (done) return;
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
    final http.StreamedResponse response;
    try {
      response = await _inner.send(copy);
    } finally {
      done = true;
      timer?.cancel();
    }
    if (upload && response.statusCode == 413) {
      throw await _tooLarge(response);
    }
    return response;
  }

  /// A refused upload as Matrix's "too large", whoever refused it. The SDK
  /// takes anything but a [MatrixException] for a dropped connection, and
  /// uploads the whole file again every second until its send limit: a
  /// proxy before the homeserver answers 413 in HTML, not Matrix's JSON.
  static Future<MatrixException> _tooLarge(
    http.StreamedResponse response,
  ) async {
    String? said;
    try {
      final body = jsonDecode(await response.stream.bytesToString());
      if (body is Map && body['error'] is String) {
        said = body['error'] as String;
      }
    } on Object {
      // Not JSON: a proxy's page.
    }
    return MatrixException.fromJson({
      'errcode': MatrixError.M_TOO_LARGE.name,
      'error': said ?? 'refused as too large (HTTP 413)',
    });
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
