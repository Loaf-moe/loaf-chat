/// Updates an AppImage, which nothing else will: no system mechanism knows
/// the file exists. Fetches the feed, downloads beside the running file,
/// checks the signature and the hash, and renames over it. The rename is
/// atomic, so a crash leaves the old file or the new one, never a mix.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../ui/model/updater.dart';
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
  bool _checking = false;

  /// Nothing sane is this big; refuse before filling the disk.
  static const _largest = 500 * 1024 * 1024;

  /// Checks shortly after launch, then every six hours.
  void start() {
    _timers
      ..add(Timer(const Duration(seconds: 30), check))
      ..add(Timer.periodic(const Duration(hours: 6), (_) => check()));
  }

  Future<void> check() async {
    if (_checking || state is! UpdateIdle) return;
    _checking = true;
    File? part;
    try {
      final release = await fetchRelease(_http, feed);
      final asset = release.appImage;
      if (asset == null || release.build <= build) return;
      if (!verify(release.signedText, asset.signature)) {
        throw StateError('the feed is not signed by the release key');
      }
      if (asset.size > _largest) throw StateError('${asset.size} bytes');
      move(const UpdatePreparing());

      // $APPIMAGE may be a link into ~/bin: replace what it points at.
      final target = File(await _appImage.resolveSymbolicLinks());
      part = File('${target.path}.part');
      // Idle timeouts, not total: a slow link may take as long as it needs,
      // a dead one must not hold _checking until the next launch.
      final response = await _http
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
      final sink = part.openWrite();
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

      // Fsync to disk before rename, so a power loss cannot leave the new
      // name pointing at a partial file.
      final raf = await part.open(mode: FileMode.append);
      try {
        await raf.flush();
      } finally {
        await raf.close();
      }

      final digest = await sha256.bind(part.openRead()).first;
      if (bytesWritten != asset.size || '$digest' != asset.sha256) {
        throw StateError('the download does not match the feed');
      }
      final chmod = await Process.run('chmod', ['+x', part.path]);
      if (chmod.exitCode != 0) throw StateError('chmod: ${chmod.stderr}');
      await part.rename(target.path);
      part = null;
      move(UpdateReady(release.version));
    } catch (e, s) {
      updateLog('the AppImage was not updated', e, s);
      move(const UpdateIdle());
    } finally {
      try {
        if (part != null && part.existsSync()) part.deleteSync();
      } catch (_) {}
      _checking = false;
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
