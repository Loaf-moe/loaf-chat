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

import 'package:http/http.dart' as http;

import '../ui/model/updater.dart';
import 'asset_download.dart';
import 'bundle_swap.dart';
import 'ed25519.dart';
import 'release_feed.dart';
import 'state_updater.dart';
import 'update_log.dart';

typedef Unpack = Future<void> Function(File zip, Directory into);

class WindowsUpdater extends StateUpdater {
  WindowsUpdater({
    required this.install,
    required this.build,
    required this.feed,
    required this.verify,
    this.idleTimeout = const Duration(minutes: 2),
    http.Client? httpClient,
    Unpack? unpack,
    Future<void> Function(String path)? launch,
    void Function()? quit,
  }) : _http = httpClient ?? http.Client(),
       _swap = BundleSwap(install),
       _unpack = unpack ?? _tarUnpack,
       _launch = launch ?? _launchDetached,
       _quit = quit ?? _exit;

  /// The folder Setup installed into.
  final Directory install;

  /// This copy's build number.
  final int build;
  final Uri feed;
  final SignatureCheck verify;

  /// How long a download may go without a byte before it is given up on.
  final Duration idleTimeout;
  final http.Client _http;
  final BundleSwap _swap;
  final Unpack _unpack;
  final Future<void> Function(String path) _launch;
  final void Function() _quit;

  final _timers = <Timer>[];

  /// The check under way, which a second caller waits on rather than racing.
  Future<UpdateCheck>? _checking;

  /// Clears what the last update left, then checks shortly after launch and
  /// hourly after: the AppImage's pace, so a release reaches every desktop
  /// together.
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
    _timers
      ..add(Timer(checkAfter, check))
      ..add(Timer.periodic(const Duration(hours: 1), (_) => check()));
  }

  @override
  bool get canCheck => true;

  @override
  Future<UpdateCheck> check() {
    if (state is UpdateReady || state is UpdateApplying) {
      return Future.value(UpdateCheck.ready);
    }
    return _checking ??= _check().whenComplete(() => _checking = null);
  }

  Future<UpdateCheck> _check() async {
    final work = _swap.work;
    try {
      final release = await fetchRelease(_http, feed);
      final asset = release.windows;
      if (asset == null || release.build <= build) return UpdateCheck.upToDate;
      if (!verify(release.signedTextFor(AssetKind.windows), asset.signature)) {
        throw StateError('the feed is not signed by the release key');
      }
      if (asset.size > largestAsset) throw StateError('${asset.size} bytes');
      move(const UpdatePreparing());

      // Inside the install, so every rename of the swap stays on one volume.
      if (work.existsSync()) work.deleteSync(recursive: true);
      work.createSync(recursive: true);
      final zip = File('${work.path}${Platform.pathSeparator}build.zip');
      await downloadAsset(_http, asset, zip, idleTimeout: idleTimeout);
      final staged = Directory('${work.path}${Platform.pathSeparator}staged')
        ..createSync();
      await _unpack(zip, staged);
      await _swap.apply(staged);
      move(UpdateReady(release.version));
      return UpdateCheck.ready;
    } catch (e, s) {
      updateLog('Windows was not updated', e, s);
      move(const UpdateIdle());
      return UpdateCheck.failed;
    } finally {
      try {
        if (work.existsSync()) work.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  @override
  Future<void> restart() async {
    final ready = state;
    if (ready is! UpdateReady) return;
    move(UpdateApplying(ready.version));
    final exe =
        '${install.path}${Platform.pathSeparator}${BundleSwap.executable}';
    try {
      await _launch(exe);
    } catch (e, s) {
      updateLog('the new build did not start', e, s);
      move(ready);
      return;
    }
    _quit();
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _http.close();
    super.dispose();
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

Future<void> _launchDetached(String path) =>
    Process.start(path, const [], mode: ProcessStartMode.detached);

void _exit() => exit(0);
