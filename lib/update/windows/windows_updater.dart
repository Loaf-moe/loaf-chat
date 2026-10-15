/// Updates a Windows install, which nothing else will: an unsigned app has
/// no system updater. Works like the AppImage's: fetches the feed, checks
/// the signature, downloads and hashes the zip of the new build, unpacks it
/// beside the install, and swaps it in with [BundleSwap].
///
/// The swap happens as soon as the build is verified, as the AppImage's
/// rename does. The running build keeps the code it has loaded; the next
/// launch, whenever it comes, is the new one.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../feed/release_feed.dart';
import '../feed/verified_asset.dart';
import '../self_updater.dart';
import '../update_log.dart';
import 'bundle_swap.dart';

typedef Unpack = Future<void> Function(File zip, Directory into);

class WindowsUpdater extends SelfUpdater {
  WindowsUpdater({
    required this.installation,
    required super.build,
    required super.feed,
    required super.verify,
    super.idleTimeout,
    super.restarter,
    super.httpClient,
    this._unpack = _tarUnpack,
  }) : _swap = BundleSwap(installation.path);

  /// The folder Setup installed into.
  final Directory installation;
  final BundleSwap _swap;
  final Unpack _unpack;

  @override
  AssetKind get kind => AssetKind.windows;

  @override
  String get relaunchPath =>
      p.join(installation.path, BundleSwap.executable.posix);

  /// Clears what the last update left first.
  @override
  Future<void> start({
    Duration checkAfter = const Duration(seconds: 30),
  }) async {
    try {
      if (await _swap.cleanUp()) {
        updateLog('an update cut short was undone');
      }
    } catch (e, s) {
      updateLog('could not clear the last update', e, s);
    }
    await super.start(checkAfter: checkAfter);
  }

  @override
  Future<void> install(VerifiedAsset asset) async {
    // Inside the install, so every rename of the swap stays on one volume.
    final work = _swap.work;
    try {
      if (work.existsSync()) work.deleteSync(recursive: true);
      work.createSync(recursive: true);
      final zip = await asset.fetch(
        client,
        work.childFile('build.zip'),
        idleTimeout: idleTimeout,
      );
      final staged = work.childDirectory('staged')..createSync();
      await _unpack(zip, staged);
      await _swap.apply(staged);
    } finally {
      try {
        if (work.existsSync()) work.deleteSync(recursive: true);
      } on FileSystemException {
        // Held; the next launch's clean-up gets it.
      }
    }
  }
}

/// Windows' own bsdtar (since 1803) reads zips, and refuses entries that
/// climb out with `..`. By full path, so nothing earlier on PATH stands in.
Future<void> _tarUnpack(File zip, Directory into) async {
  final system = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  final result = await Process.run('$system\\System32\\tar.exe', [
    '-xf',
    zip.path,
    '-C',
    into.path,
  ]);
  if (result.exitCode != 0) {
    throw ProcessException(
      'tar',
      const [],
      '${result.stderr}',
      result.exitCode,
    );
  }
}
