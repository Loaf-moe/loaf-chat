/// A build named in the feed that is newer than this one and signed by the
/// release key. The only way to a download: an asset that fails either
/// test never becomes one.
library;

import 'dart:io';

import 'package:http/http.dart' as http;

import '../../util/http_download.dart';
import 'ed25519.dart';
import 'release_feed.dart';

/// Nothing sane is this big; refuse before filling the disk.
const largestAsset = 500 * 1024 * 1024;

final class VerifiedAsset {
  const VerifiedAsset._(this.release, this.asset);

  final Release release;
  final ReleaseAsset asset;

  String get version => release.version;

  /// [release]'s [kind] build if it is newer than [build]: null when it is
  /// not, or when [release] offers no such build. Throws a [StateError] for
  /// one the release key did not sign, or one too big to be real.
  static VerifiedAsset? check(
    Release release,
    AssetKind kind,
    SignatureCheck verify, {
    required int build,
  }) {
    final asset = release.assets[kind];
    if (asset == null || release.build <= build) return null;
    if (!verify(release.signedTextFor(kind), asset.signature)) {
      throw StateError('the feed is not signed by the release key');
    }
    if (asset.size > largestAsset) {
      throw StateError('${asset.size} bytes is more than any build');
    }
    return VerifiedAsset._(release, asset);
  }

  /// Downloads it to [to], which appears only whole and matching the hash
  /// the signature vouches for. [idleTimeout] limits silence, not the
  /// whole download.
  Future<File> fetch(
    http.Client client,
    File to, {
    required Duration idleTimeout,
  }) => download(
    client,
    asset.url,
    to,
    size: asset.size,
    sha256: asset.sha256,
    idleTimeout: idleTimeout,
  );
}
