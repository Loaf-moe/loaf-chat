/// Updates an AppImage, which nothing else will: no system mechanism knows
/// the file exists. Fetches the feed, downloads beside the running file,
/// checks the signature and the hash, and renames over it. The rename is
/// atomic, so a crash leaves the old file or the new one, never a mix.
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../ui/model/updater.dart';
import 'asset_download.dart';
import 'ed25519.dart';
import 'release_feed.dart';
import 'state_updater.dart';
import 'update_log.dart';

class AppImageUpdater extends StateUpdater {
  AppImageUpdater({
    required this._appImage,
    required this.build,
    required this.feed,
    required this.verify,
    this.idleTimeout = const Duration(minutes: 2),
    http.Client? httpClient,
    Future<void> Function(String path)? launch,
    void Function()? quit,
  }) : _http = httpClient ?? http.Client(),
       _launch = launch ?? _launchDetached,
       _quit = quit ?? _exit;

  final File _appImage;

  /// This copy's build number.
  final int build;
  final Uri feed;
  final SignatureCheck verify;

  /// How long a download may go without a byte before it is given up on.
  final Duration idleTimeout;
  final http.Client _http;
  final Future<void> Function(String path) _launch;
  final void Function() _quit;

  final _timers = <Timer>[];

  /// The check under way, which a second caller waits on rather than racing.
  Future<UpdateCheck>? _checking;

  /// Checks shortly after launch, then hourly: as often as Sparkle allows
  /// on macOS, so a release reaches every desktop at the same pace.
  void start() {
    _timers
      ..add(Timer(const Duration(seconds: 30), check))
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
    File? part;
    try {
      final release = await fetchRelease(_http, feed);
      final asset = release.appImage;
      if (asset == null || release.build <= build) return UpdateCheck.upToDate;
      if (!verify(release.signedTextFor(AssetKind.appImage), asset.signature)) {
        throw StateError('the feed is not signed by the release key');
      }
      if (asset.size > largestAsset) throw StateError('${asset.size} bytes');
      move(const UpdatePreparing());

      // $APPIMAGE may be a link into ~/bin: replace what it points at.
      final target = File(await _appImage.resolveSymbolicLinks());
      part = File('${target.path}.part');
      await downloadAsset(_http, asset, part, idleTimeout: idleTimeout);
      final chmod = await Process.run('chmod', ['+x', part.path]);
      if (chmod.exitCode != 0) throw StateError('chmod: ${chmod.stderr}');
      await part.rename(target.path);
      part = null;
      move(UpdateReady(release.version));
      return UpdateCheck.ready;
    } catch (e, s) {
      updateLog('the AppImage was not updated', e, s);
      move(const UpdateIdle());
      return UpdateCheck.failed;
    } finally {
      try {
        if (part != null && part.existsSync()) part.deleteSync();
      } catch (_) {}
    }
  }

  @override
  Future<void> restart() async {
    final ready = state;
    if (ready is! UpdateReady) return;
    move(UpdateApplying(ready.version));
    try {
      await _launch(_appImage.path);
    } catch (e, s) {
      updateLog('the new AppImage did not start', e, s);
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

Future<void> _launchDetached(String path) =>
    Process.start(path, const [], mode: ProcessStartMode.detached);

void _exit() => exit(0);
