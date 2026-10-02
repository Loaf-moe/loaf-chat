/// Pictures for media rows: files the [MediaStore] downloads, and the bytes
/// the SDK holds for a message that is still going up.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
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
      final buffer = await ImmutableBuffer.fromUint8List(
        await File(path).readAsBytes(),
      );
      final target = bucket;
      return await decode(
        buffer,
        getTargetSize: target == null
            ? null
            // Never up: a small picture keeps its own size.
            : (w, h) => TargetImageSize(width: math.min(target, w)),
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
    return decode(await ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is FileStoreImage && other.uri == uri && other.fallback == fallback;

  @override
  int get hashCode => Object.hash(uri, fallback);
}
