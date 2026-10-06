/// Pictures for media rows: files the [MediaStore] downloads, and the bytes
/// the SDK holds for a message that is still going up.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:loaf_media/loaf_media.dart';
import 'package:matrix/matrix.dart';

import '../ui/model/media_source.dart';
import 'matrix_avatar_images.dart';

/// A downloaded (and, when need be, decrypted) picture, decoded no larger
/// than its width in physical px so a photo doesn't decode at full size to fill a
/// 400 px row. A null width decodes it whole, for the viewer.
class StoredFileImage extends ImageProvider<StoredFileImage> {
  StoredFileImage(this.file, double? width)
    : bucket = width == null
          ? null
          : bucketFor(width, buckets: timelineBuckets);

  final MediaFile file;

  /// [width] rounded up to a size servers and the cache share, so rows
  /// asking for nearby widths share one decoded picture. Null: whole.
  final int? bucket;

  @override
  Future<StoredFileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    StoredFileImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _codec(decode), scale: 1);

  Future<Codec> _codec(ImageDecoderCallback decode) async {
    // Held across the load so that eviction can't take it from under us.
    file.hold();
    try {
      final path = await file.path;
      return await decodeWithFallback(
        await File(path).readAsBytes(),
        decode,
        width: bucket,
      );
    } finally {
      file.release();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is StoredFileImage &&
      other.file.id == file.id &&
      other.bucket == bucket;

  @override
  int get hashCode => Object.hash(file.id, bucket);
}

/// What the SDK stored for a message while it uploads, by its `cache://` uri.
/// Throws when there is nothing there, so the row says so rather than
/// showing a blank.
class FileStoreImage extends ImageProvider<FileStoreImage> {
  FileStoreImage(this.client, this.uri, {this.fallback});

  final Client client;
  final Uri uri;

  /// Tried when [uri] holds nothing: the full image for want of a thumbnail.
  final Uri? fallback;

  @override
  Future<FileStoreImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    FileStoreImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _codec(decode), scale: 1);

  Future<Codec> _codec(ImageDecoderCallback decode) async {
    final bytes =
        await client.database.getFile(uri) ??
        (fallback == null ? null : await client.database.getFile(fallback!));
    if (bytes == null) throw StateError('nothing stored for $uri');
    return decodeWithFallback(bytes, decode);
  }

  @override
  bool operator ==(Object other) =>
      other is FileStoreImage && other.uri == uri && other.fallback == fallback;

  @override
  int get hashCode => Object.hash(uri, fallback);
}

typedef WicDecode = Future<DecodedImage> Function(
  Uint8List bytes, {
  int? maxWidth,
});

/// Decodes [bytes] with Flutter's codecs, no wider than [width] (never up:
/// a small picture keeps its own size). On Windows, a picture they refuse
/// (an iPhone's HEIC, an AVIF) goes to WIC, which reads whatever the machine
/// has codecs for. Elsewhere, and when WIC can't either, Flutter's error
/// stands and the row says it couldn't load.
Future<Codec> decodeWithFallback(
  Uint8List bytes,
  ImageDecoderCallback decode, {
  int? width,
  @visibleForTesting bool? windows,
  @visibleForTesting WicDecode? wic,
}) async {
  try {
    return await decode(
      await ImmutableBuffer.fromUint8List(bytes),
      getTargetSize: width == null
          ? null
          : (w, h) => TargetImageSize(width: math.min(width, w)),
    );
  } catch (e) {
    if (!(windows ?? defaultTargetPlatform == TargetPlatform.windows)) {
      rethrow;
    }
    final DecodedImage decoded;
    try {
      decoded = await (wic ?? LoafMedia.decodeImage)(bytes, maxWidth: width);
    } catch (wicError) {
      debugPrint('[loaf media] WIC: $wicError');
      rethrow;
    }
    final descriptor = ImageDescriptor.raw(
      await ImmutableBuffer.fromUint8List(decoded.pixels),
      width: decoded.width,
      height: decoded.height,
      pixelFormat: PixelFormat.rgba8888,
    );
    return descriptor.instantiateCodec();
  }
}
