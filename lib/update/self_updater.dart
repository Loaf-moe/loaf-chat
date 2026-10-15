/// What the AppImage and Windows updaters share: they fetch, verify and
/// install their own builds from the feed, because nothing on their
/// platform will. Each says only which build is its own, how to put it in
/// place, and what to start afterwards.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'feed/ed25519.dart';
import 'feed/release_feed.dart';
import 'feed/verified_asset.dart';
import 'restarter.dart';
import 'state_updater.dart';
import 'update_log.dart';
import 'updater.dart';

abstract class SelfUpdater extends StateUpdater {
  SelfUpdater({
    required this.build,
    required this.feed,
    required this.verify,
    this.idleTimeout = const Duration(minutes: 2),
    this.restarter = const Restarter(),
    http.Client? httpClient,
  }) : client = httpClient ?? http.Client();

  /// This copy's build number.
  final int build;
  final Uri feed;
  final SignatureCheck verify;

  /// How long a download may go without a byte before it is given up on.
  final Duration idleTimeout;
  final Restarter restarter;

  @protected
  final http.Client client;

  final _timers = <Timer>[];

  /// The check under way, which a second caller waits on rather than racing.
  Future<UpdateCheck>? _checking;

  /// Which build in the feed is this platform's.
  @protected
  AssetKind get kind;

  /// Puts [asset] in place of the running build, so the next launch is the
  /// new one. Throws, with the running build left as it was, if it cannot.
  @protected
  Future<void> install(VerifiedAsset asset);

  /// What to start to run the build [install] put in place.
  @protected
  String get relaunchPath;

  /// Checks shortly after launch, then hourly: as often as Sparkle allows
  /// on macOS, so a release reaches every desktop at the same pace.
  Future<void> start({
    Duration checkAfter = const Duration(seconds: 30),
  }) async {
    _timers
      ..add(Timer(checkAfter, check))
      ..add(Timer.periodic(const Duration(hours: 1), (_) => check()));
  }

  @override
  bool get canCheck => true;

  @override
  Future<UpdateCheck> check() {
    if (state.staged) return Future.value(UpdateCheck.ready);
    return _checking ??= _check().whenComplete(() => _checking = null);
  }

  Future<UpdateCheck> _check() async {
    try {
      final release = await fetchRelease(client, feed);
      final asset = VerifiedAsset.check(release, kind, verify, build: build);
      if (asset == null) return UpdateCheck.upToDate;
      transition(const UpdatePreparing());
      await install(asset);
      transition(UpdateReady(asset.version));
      return UpdateCheck.ready;
    } catch (e, s) {
      updateLog('the ${kind.key} build was not installed', e, s);
      transition(const UpdateIdle());
      return UpdateCheck.failed;
    }
  }

  @override
  Future<void> relaunch() async {
    await restarter.launch(relaunchPath);
    restarter.quit();
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    client.close();
    super.dispose();
  }
}
