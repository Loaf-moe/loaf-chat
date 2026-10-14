/// Avatars from the homeserver's media repository: `mxc://` uris fetched as
/// thumbnails, kept in the SDK's file store so a relaunch draws from disk.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:matrix/matrix.dart';

import '../ui/model/models.dart';
import '../ui/widgets/avatar_images.dart';
import 'media_images.dart';

/// 64, 128 and 320 physical px: the sizes servers pre-generate, so their
/// thumbnails are reused rather than made per request.
const avatarBuckets = [64, 128, 320];

/// What a row's picture rounds up to: the server's thumbnail sizes.
const timelineBuckets = [320, 640, 1280];

/// The smallest of [buckets] that holds [physical] px, or the largest.
int bucketFor(double physical, {List<int> buckets = avatarBuckets}) =>
    buckets.firstWhere((b) => physical <= b, orElse: () => buckets.last);

class MatrixAvatarImages implements AvatarImages {
  MatrixAvatarImages(
    this.client, {
    this.warmAfter = defaultWarmAfter,
    this.fetchTimeout = const Duration(seconds: 60),
  });

  /// Long enough for the first sync to land first.
  static const defaultWarmAfter = Duration(seconds: 5);

  final Client client;

  /// How long the first warm fetch waits.
  final Duration warmAfter;

  /// A warm fetch slower than this is given up on, so one dead download
  /// never parks the rest.
  final Duration fetchTimeout;

  final _warmed = <Uri>{};
  final _pending = Queue<Uri>();
  Timer? _timer;
  Timer? _fetchTimer;
  var _started = false;
  var _draining = false;
  var _disposed = false;

  /// Fetches [ref]'s original into the file store, after the others asked
  /// for before it, so the card and the call tile have it at once.
  void warm(AvatarRef ref) {
    final uri = _mxc(ref);
    if (uri == null || _disposed || !_warmed.add(uri)) return;
    _pending.add(uri);
    if (_started) {
      if (!_draining) unawaited(_drain());
    } else {
      _timer ??= Timer(warmAfter, () {
        _started = true;
        unawaited(_drain());
      });
    }
  }

  Future<void> _drain() async {
    _draining = true;
    while (_pending.isNotEmpty && !_disposed) {
      try {
        await _fetch(_pending.removeFirst());
      } on Object {
        // Logged by bytes(), or timed out; the next avatar still gets its turn.
      }
    }
    _draining = false;
  }

  /// [MxcImage.bytes] bounded by [fetchTimeout]. Its own timer, not
  /// `Future.timeout`, so [dispose] can cancel it.
  Future<void> _fetch(Uri uri) {
    final done = Completer<void>();
    final timer = _fetchTimer = Timer(fetchTimeout, () {
      if (!done.isCompleted) {
        done.completeError(TimeoutException(uri.toString()));
      }
    });
    unawaited(
      MxcImage(client, uri)
          .bytes()
          .then(
            (_) {
              if (!done.isCompleted) done.complete();
            },
            onError: (Object e) {
              if (!done.isCompleted) done.completeError(e);
            },
          )
          .whenComplete(timer.cancel),
    );
    return done.future;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _fetchTimer?.cancel();
  }

  @override
  ImageProvider? resolve(AvatarRef ref, double physicalSize) {
    final uri = _mxc(ref);
    return uri == null
        ? null
        : MxcImage(client, uri, size: bucketFor(physicalSize));
  }

  @override
  ImageProvider? original(AvatarRef ref) {
    final uri = _mxc(ref);
    return uri == null ? null : MxcImage(client, uri);
  }

  Uri? _mxc(AvatarRef ref) {
    final uri = Uri.tryParse(ref.value);
    return uri == null || !uri.isScheme('mxc') ? null : uri;
  }
}

/// A server thumbnail of [mxc] at [size], or with no size the upload itself.
class MxcImage extends ImageProvider<MxcImage> {
  MxcImage(this.client, this.mxc, {this.size});

  final Client client;
  final Uri mxc;
  final int? size;

  @override
  Future<MxcImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(MxcImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _codec(decode), scale: 1);

  /// An upload is drawn at 128 logical at most; this covers 3x with room.
  static const _originalWidth = 512;

  Future<Codec> _codec(ImageDecoderCallback decode) async {
    final bytes = await this.bytes();
    // A thumbnail the server already sized decodes as is.
    if (size != null) return decode(await ImmutableBuffer.fromUint8List(bytes));
    return decodeWithFallback(bytes, decode, width: _originalWidth);
  }

  /// Throws on any failure: the widget keeps what it had, and nothing is
  /// cached.
  Future<Uint8List> bytes() async {
    try {
      final size = this.size;
      final uri = size == null
          ? await mxc.getDownloadUri(client)
          : await mxc.getThumbnailUri(client, width: size, height: size);
      // No homeserver (signed out mid-load) gives an empty uri.
      if (!uri.hasScheme) throw StateError('no media server for $mxc');
      // The file store is keyed per uri, so each size keeps its own.
      final cached = await client.database.getFile(uri);
      if (cached != null) return cached;
      final response = await client.httpClient.get(
        uri,
        headers: {'authorization': 'Bearer ${client.accessToken}'},
      );
      final type = response.headers['content-type'] ?? '';
      if (response.statusCode != 200 || !type.startsWith('image/')) {
        throw StateError('no image for $mxc (${response.statusCode})');
      }
      await client.database.storeFile(
        uri,
        response.bodyBytes,
        DateTime.now().millisecondsSinceEpoch,
      );
      return response.bodyBytes;
    } catch (e) {
      Logs().v('avatar $mxc: $e');
      rethrow;
    }
  }

  // Not on [client]: one account's picture is the same picture.
  @override
  bool operator ==(Object other) =>
      other is MxcImage && other.mxc == mxc && other.size == size;

  @override
  int get hashCode => Object.hash(mxc, size);
}
