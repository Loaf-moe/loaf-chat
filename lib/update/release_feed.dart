/// `latest.json`: what the newest release is, and where its AppImage lives.
/// The AppImage updater acts on it; the Flatpak updater only reads the
/// version out of it, because the portal speaks in commits.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class AppImageAsset {
  const AppImageAsset({
    required this.url,
    required this.sha256,
    required this.size,
    required this.signature,
  });

  final Uri url;
  final String sha256;
  final int size;

  /// Ed25519 over [Release.signedText], base64.
  final String signature;
}

class Release {
  const Release({required this.version, required this.build, this.appImage});

  final String version;

  /// What decides newer from older. Version names are for people.
  final int build;
  final AppImageAsset? appImage;

  /// Throws a [FormatException] for anything that is not a feed: a captive
  /// portal's page, a truncated body, a field of the wrong type.
  static Release parse(String body) {
    final json = jsonDecode(body);
    if (json case {'version': final String version, 'build': final int build}) {
      return Release(
        version: version,
        build: build,
        appImage: switch (json['appimage']) {
          {
            'url': final String url,
            'sha256': final String sha256,
            'size': final int size,
            'signature': final String signature,
          } =>
            AppImageAsset(
              url: Uri.parse(url),
              sha256: sha256,
              size: size,
              signature: signature,
            ),
          _ => null,
        },
      );
    }
    throw const FormatException('not a release feed');
  }

  /// What the release key signs. It names the hash rather than being the
  /// file: the verifier takes text, and the hash then vouches for the file.
  String get signedText =>
      'loaf-chat-appimage\n$version\n$build\n${appImage!.sha256}';
}

Future<Release> fetchRelease(http.Client client, Uri feed) async {
  final response = await client.get(feed).timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) {
    throw HttpException('the feed answered ${response.statusCode}', uri: feed);
  }
  return Release.parse(response.body);
}
