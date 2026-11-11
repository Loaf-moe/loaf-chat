/// Updates the macOS app through Sparkle, which checks, downloads, verifies
/// and installs. Sparkle shows no windows of its own here: it reports over
/// the typed API in `sparkle.g.dart` (from `pigeons/sparkle.dart`), and the
/// rail's notice is the only thing you see. The other end is
/// `macos/Runner/UpdaterBridge.swift`.
library;

import 'dart:async';

import '../state_updater.dart';
import '../update_log.dart';
import '../updater.dart';
import 'sparkle.g.dart';

class SparkleUpdater extends StateUpdater {
  SparkleUpdater({SparkleHost? host}) : _host = host ?? SparkleHost() {
    SparkleEvents.setUp(_Events(this));
    // Only now: an event sent before anyone listens would be lost.
    unawaited(_start());
  }

  final SparkleHost _host;
  var _started = false;

  Future<void> _start() async {
    try {
      await _host.start();
      _started = true;
      notifyListeners();
    } catch (e) {
      updateLog('Sparkle did not start', e);
    }
  }

  @override
  bool get canCheck => _started;

  /// Sparkle answers as soon as it knows whether there is anything newer;
  /// what it found is then fetched, and the answer here waits for that too.
  @override
  Future<UpdateCheck> check() async {
    if (state is! UpdateIdle) return settled();
    final SparkleCheck answer;
    try {
      answer = await _host.check();
    } catch (e, s) {
      updateLog('Sparkle did not check', e, s);
      return UpdateCheck.failed;
    }
    switch (answer) {
      case SparkleCheck.upToDate:
        return UpdateCheck.upToDate;
      case SparkleCheck.found:
        // Sparkle says preparing too, but don't hang on which lands first.
        if (state is UpdateIdle) transition(const UpdatePreparing());
        return settled();
      case SparkleCheck.failed:
        return UpdateCheck.failed;
    }
  }

  /// For [_Events], which is not a [StateUpdater] and may not call it.
  void _become(UpdateState next) => transition(next);

  /// Sparkle installs, relaunches, and quits this process itself.
  @override
  Future<void> relaunch() => _host.restart();

  @override
  void dispose() {
    SparkleEvents.setUp(null);
    super.dispose();
  }
}

/// Sparkle's events, each a state.
class _Events implements SparkleEvents {
  _Events(this._updater);

  final SparkleUpdater _updater;

  @override
  void idle() => _updater._become(const UpdateIdle());

  @override
  void preparing() => _updater._become(const UpdatePreparing());

  @override
  void ready(String? version) => _updater._become(UpdateReady(version));
}
