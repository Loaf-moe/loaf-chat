/// Tells the native players how far each file they read has arrived, so a
/// read past the end can wait for the bytes rather than fail. The Swift end
/// is `darwin/loaf_media/Sources/loaf_media/VideoStreams.swift`.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'growing_file.dart';

abstract final class VideoStreams {
  static const _channel = MethodChannel('moe.loaf.chat/media');

  /// How often progress is sent while a file arrives. A download notifies
  /// per chunk, far more often than a player needs to hear.
  static const _interval = Duration(milliseconds: 100);

  static final _streams = <String, _Stream>{};

  /// Starts reporting [file] to the native side, or counts one more player
  /// of it: every player of one file shares one stream. Balanced by
  /// [detach].
  static void attach(GrowingFile file) {
    final stream = _streams[file.id];
    if (stream != null) {
      stream.players++;
      return;
    }
    _streams[file.id] = _Stream(file)..begin();
  }

  /// The last player of [file] is gone: the native side lets go of it.
  static void detach(GrowingFile file) {
    final stream = _streams[file.id];
    if (stream == null) return;
    if (--stream.players > 0) return;
    _streams.remove(file.id);
    stream.end();
  }

  static void _send(String method, Map<String, Object?> arguments) {
    unawaited(
      _channel.invokeMethod<void>(method, arguments).catchError((Object e) {
        debugPrint('[loaf media] $method: $e');
      }),
    );
  }
}

class _Stream {
  _Stream(this.file);

  final GrowingFile file;
  var players = 1;
  Timer? _timer;

  /// Whether the last thing sent said the download had failed. A retry
  /// after that writes a new file, which the native side must open afresh.
  var _failedSent = false;

  Map<String, Object?> get _progress => {
    'id': file.id,
    'received': file.received,
    'total': file.total,
    'complete': file.complete,
    'failed': file.error != null,
  };

  void begin() {
    _failedSent = file.error != null;
    VideoStreams._send('stream.begin', {
      ..._progress,
      'path': file.partialPath,
    });
    file.addListener(_changed);
  }

  void end() {
    file.removeListener(_changed);
    _timer?.cancel();
    _timer = null;
    VideoStreams._send('stream.end', {'id': file.id});
  }

  void _changed() {
    if (_failedSent && file.error == null) {
      _timer?.cancel();
      _timer = null;
      file.removeListener(_changed);
      begin();
      return;
    }
    // The end of a download, either way, is never held back: a player
    // waiting on the last bytes, or for the failure, hears at once.
    if (file.complete || file.error != null) {
      _timer?.cancel();
      _timer = null;
      _sendProgress();
      return;
    }
    _timer ??= Timer(VideoStreams._interval, () {
      _timer = null;
      _sendProgress();
    });
  }

  void _sendProgress() {
    _failedSent = file.error != null;
    VideoStreams._send('stream.progress', _progress);
  }
}
