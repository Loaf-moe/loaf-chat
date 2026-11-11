/// `latest.json`: what the newest release is, and where each build of it
/// lives. The AppImage and Windows updaters act on it; the Flatpak updater
/// only reads the version out of it, because the portal speaks in commits.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// The builds a release offers, by the key each has in the feed.
enum AssetKind {
  appImage('appimage'),
  windows('windows');

  const AssetKind(this.key);

  /// Its field in `latest.json`, and the start of what the key signs.
  final String key;
}

class ReleaseAsset {
  const ReleaseAsset({
    required this.url,
    required this.sha256,
    required this.size,
    required this.signature,
  });

  final Uri url;
  final String sha256;
  final int size;

  /// Ed25519 over [Release.signedTextFor] this asset's kind, base64.
  final String signature;

  static ReleaseAsset? _parse(Object? json) => switch (json) {
    {
      'url': final String url,
      'sha256': final String sha256,
      'size': final int size,
      'signature': final String signature,
    } =>
      ReleaseAsset(
        url: Uri.parse(url),
        sha256: sha256,
        size: size,
        signature: signature,
      ),
    _ => null,
  };
}

class Release {
  const Release({
    required this.version,
    required this.build,
    this.assets = const {},
  });

  final String version;

  /// What decides newer from older. Version names are for people.
  final int build;
  final Map<AssetKind, ReleaseAsset> assets;

  ReleaseAsset? get appImage => assets[AssetKind.appImage];
  ReleaseAsset? get windows => assets[AssetKind.windows];

  /// Throws a [FormatException] for anything that is not a feed: a captive
  /// portal's page, a truncated body, a field of the wrong type.
  static Release parse(String body) {
    final json = jsonDecode(body);
    if (json case {'version': final String version, 'build': final int build}) {
      return Release(
        version: version,
        build: build,
        assets: {
          for (final kind in AssetKind.values)
            kind: ?ReleaseAsset._parse(json[kind.key]),
        },
      );
    }
    throw const FormatException('not a release feed');
  }

  /// What the release key signs for [kind]'s asset. It names the hash
  /// rather than being the file: the verifier takes text, and the hash then
  /// vouches for the file. The kind leads, so a signature for one build can
  /// never pass for another's.
  String signedTextFor(AssetKind kind) =>
      'loaf-chat-${kind.key}\n$version\n$build\n${assets[kind]!.sha256}';
}

Future<Release> fetchRelease(http.Client client, Uri feed) async {
  final response = await client.get(feed).timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) {
    throw HttpException('the feed answered ${response.statusCode}', uri: feed);
  }
  return Release.parse(response.body);
}
