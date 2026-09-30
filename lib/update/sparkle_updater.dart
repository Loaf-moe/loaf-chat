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

  Future<void> _start() async {
    try {
      await _channel.invokeMethod<void>('start');
    } catch (e) {
      updateLog('Sparkle did not start', e);
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
