/// Updates the macOS app through Sparkle, which checks, downloads, verifies
/// and installs. Sparkle shows no windows of its own here: it reports over
/// a method channel, and the rail's notice is the only thing you see.
/// The other end is `macos/Runner/UpdaterBridge.swift`.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../ui/model/updater.dart';
import 'state_updater.dart';
import 'update_log.dart';

class SparkleUpdater extends StateUpdater {
  SparkleUpdater({
    this._channel = const MethodChannel('moe.loaf.chat/updater'),
  }) {
    _channel.setMethodCallHandler(_onCall);
    // Only now: a state sent before anyone listens would be lost.
    unawaited(_start());
  }

  final MethodChannel _channel;
  var _started = false;

  Future<void> _start() async {
    try {
      await _channel.invokeMethod<void>('start');
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
    final String? answer;
    try {
      answer = await _channel.invokeMethod<String>('check');
    } catch (e, s) {
      updateLog('Sparkle did not check', e, s);
      return UpdateCheck.failed;
    }
    switch (answer) {
      case 'upToDate':
        return UpdateCheck.upToDate;
      case 'found':
        // Sparkle says preparing too, but don't hang on which lands first.
        if (state is UpdateIdle) move(const UpdatePreparing());
        return settled();
      default:
        return UpdateCheck.failed;
    }
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'state') return;
    final args = call.arguments;
    if (args is! Map) return;
    move(switch (args['state']) {
      'preparing' => const UpdatePreparing(),
      'ready' => UpdateReady(args['version'] as String?),
      _ => const UpdateIdle(),
    });
  }

  @override
  Future<void> restart() async {
    final ready = state;
    if (ready is! UpdateReady) return;
    move(UpdateApplying(ready.version));
    try {
      await _channel.invokeMethod<void>('restart');
    } catch (e, s) {
      updateLog('Sparkle did not restart the app', e, s);
      move(ready);
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
