/// Fetching one build named in the feed, for the updaters that fetch their
/// own: the AppImage and Windows.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'release_feed.dart';
import 'update_log.dart';

/// Nothing sane is this big; refuse before filling the disk.
const largestAsset = 500 * 1024 * 1024;

/// Writes [asset] to [to] and checks it against the feed: its size, then
/// its hash. Throws on any failure, and may leave [to] behind for the
/// caller to remove. [idleTimeout] limits silence, not the whole download:
/// a slow link may take as long as it needs, a dead one must not hold the
/// check until the next launch.
Future<void> downloadAsset(
  http.Client client,
  ReleaseAsset asset,
  File to, {
  required Duration idleTimeout,
}) async {
  final response = await client
      .send(http.Request('GET', asset.url))
      .timeout(idleTimeout);
  if (response.statusCode != 200) {
    throw HttpException('${response.statusCode}', uri: asset.url);
  }
  // Refuse up front if Content-Length differs from expected size.
  final contentLength = response.contentLength;
  if (contentLength != null &&
      contentLength != -1 &&
      contentLength != asset.size) {
    throw StateError('Content-Length $contentLength != ${asset.size}');
  }

  // Write to file while counting bytes and refusing if oversized.
  var bytesWritten = 0;
  final sink = to.openWrite();
  try {
    await response.stream.timeout(idleTimeout).forEach((bytes) {
      bytesWritten += bytes.length;
      if (bytesWritten > asset.size) {
        throw StateError('download exceeded ${asset.size} bytes');
      }
      sink.add(bytes);
    });
  } finally {
    try {
      await sink.flush();
    } catch (e) {
      updateLog('could not finish writing the download', e);
    }
    try {
      await sink.close();
    } catch (e) {
      updateLog('could not finish writing the download', e);
    }
  }

  // Fsync to disk before anyone renames it, so a power loss cannot leave
  // the new name pointing at a partial file.
  final raf = await to.open(mode: FileMode.append);
  try {
    await raf.flush();
  } finally {
    await raf.close();
  }

  final digest = await sha256.bind(to.openRead()).first;
  if (bytesWritten != asset.size || '$digest' != asset.sha256) {
    throw StateError('the download does not match the feed');
  }
}
