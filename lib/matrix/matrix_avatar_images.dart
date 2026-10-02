/// Avatars from the homeserver's media repository: `mxc://` uris fetched as
/// thumbnails, kept in the SDK's file store so a relaunch draws from disk.
library;

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:matrix/matrix.dart';

import '../ui/model/models.dart';
import '../ui/widgets/avatar_images.dart';

/// 64, 128 and 320 physical px: the sizes servers pre-generate, so their
/// thumbnails are reused rather than made per request.
const avatarBuckets = [64, 128, 320];

/// What a row's picture rounds up to: the server's thumbnail sizes.
const timelineBuckets = [320, 640, 1280];

/// The smallest of [buckets] that holds [physical] px, or the largest.
int bucketFor(double physical, {List<int> buckets = avatarBuckets}) =>
    buckets.firstWhere((b) => physical <= b, orElse: () => buckets.last);

class MatrixAvatarImages implements AvatarImages {
  MatrixAvatarImages(this.client);

  final Client client;

  @override
  ImageProvider? resolve(AvatarRef ref, double physicalSize) {
    final uri = Uri.tryParse(ref.value);
    if (uri == null || !uri.isScheme('mxc')) return null;
    return MxcThumbnail(client, uri, bucketFor(physicalSize));
  }
}

class MxcThumbnail extends ImageProvider<MxcThumbnail> {
  MxcThumbnail(this.client, this.mxc, this.size);

  final Client client;
  final Uri mxc;
  final int size;

  @override
  Future<MxcThumbnail> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    MxcThumbnail key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(codec: _codec(decode), scale: 1);

  Future<Codec> _codec(ImageDecoderCallback decode) async =>
      decode(await ImmutableBuffer.fromUint8List(await bytes()));

  /// Throws on any failure: the widget keeps its initials, and nothing
  /// is cached.
  Future<Uint8List> bytes() async {
    try {
      final uri = await mxc.getThumbnailUri(client, width: size, height: size);
      // No homeserver (signed out mid-load) gives an empty uri.
      if (!uri.hasScheme) throw StateError('no media server for $mxc');
      // The file store is keyed per thumbnail uri, so each bucket keeps its
      // own.
      final cached = await client.database.getFile(uri);
      if (cached != null) return cached;
      final response = await client.httpClient.get(
        uri,
        headers: {'authorization': 'Bearer ${client.accessToken}'},
      );
      final type = response.headers['content-type'] ?? '';
      if (response.statusCode != 200 || !type.startsWith('image/')) {
        throw StateError('no thumbnail for $mxc (${response.statusCode})');
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

  // Not on [client]: one account's thumbnail is the same picture.
  @override
  bool operator ==(Object other) =>
      other is MxcThumbnail && other.mxc == mxc && other.size == size;

  @override
  int get hashCode => Object.hash(mxc, size);
}
