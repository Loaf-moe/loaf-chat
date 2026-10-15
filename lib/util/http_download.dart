/// Downloading one file whose size and hash are known up front.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

var _downloads = 0;

/// Fetches [url] into [to] and checks it is [size] bytes hashing to
/// [sha256] (lowercase hex). [to] only ever appears whole and verified: the
/// bytes go beside it and are renamed in at the end, and on any failure
/// they are deleted. [idleTimeout] limits silence, not the whole download,
/// so a slow link takes as long as it needs and a dead one gives up.
Future<File> download(
  http.Client client,
  Uri url,
  File to, {
  required int size,
  required String sha256,
  required Duration idleTimeout,
}) async {
  final part = File('${to.path}.$pid-${_downloads++}.part');
  try {
    final response = await client
        .send(http.Request('GET', url))
        .timeout(idleTimeout);
    if (response.statusCode != 200) {
      throw HttpException('${response.statusCode}', uri: url);
    }
    // A server that says the wrong length is refused before a byte lands.
    if (response.contentLength case final length?
        when length >= 0 && length != size) {
      throw HttpException('Content-Length $length, not $size', uri: url);
    }

    var received = 0;
    final sink = part.openWrite();
    try {
      await for (final bytes in response.stream.timeout(idleTimeout)) {
        received += bytes.length;
        if (received > size) {
          throw HttpException('more than $size bytes', uri: url);
        }
        sink.add(bytes);
      }
    } finally {
      await sink.close();
    }
    if (received != size) {
      throw HttpException('$received bytes, not $size', uri: url);
    }

    // On disk before the rename, so a power cut cannot leave [to] naming a
    // file whose bytes never arrived.
    final raf = await part.open(mode: FileMode.append);
    try {
      await raf.flush();
    } finally {
      await raf.close();
    }

    final digest = await crypto.sha256.bind(part.openRead()).first;
    if ('$digest' != sha256) {
      throw HttpException('the hash does not match', uri: url);
    }
    return await part.rename(to.path);
  } on Object {
    await part.delete().then((_) {}, onError: (_) {});
    rethrow;
  }
}
