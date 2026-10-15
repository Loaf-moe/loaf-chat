/// Updates an AppImage, which nothing else will: no system mechanism knows
/// the file exists. Downloads beside the running file and renames over it.
/// The rename is atomic, so a crash leaves the old file or the new one,
/// never a mix.
library;

import 'dart:async';
import 'dart:io';

import '../feed/release_feed.dart';
import '../feed/verified_asset.dart';
import '../self_updater.dart';

class AppImageUpdater extends SelfUpdater {
  AppImageUpdater({
    required this._appImage,
    required super.build,
    required super.feed,
    required super.verify,
    super.idleTimeout,
    super.restarter,
    super.httpClient,
  });

  final File _appImage;

  @override
  AssetKind get kind => AssetKind.appImage;

  @override
  String get relaunchPath => _appImage.path;

  @override
  Future<void> install(VerifiedAsset asset) async {
    // $APPIMAGE may be a link into ~/bin: replace what it points at.
    final target = File(await _appImage.resolveSymbolicLinks());
    final fetched = await asset.fetch(
      client,
      File('${target.path}.new'),
      idleTimeout: idleTimeout,
    );
    try {
      final chmod = await Process.run('chmod', ['+x', fetched.path]);
      if (chmod.exitCode != 0) throw StateError('chmod: ${chmod.stderr}');
      await fetched.rename(target.path);
    } on Object {
      await fetched.delete().then((_) {}, onError: (_) {});
      rethrow;
    }
  }
}
