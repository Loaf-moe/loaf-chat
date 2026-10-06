/// What the real updaters share: a state, and listeners told when it moves.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ui/model/updater.dart';

abstract class StateUpdater extends ChangeNotifier implements Updater {
  UpdateState _state = const UpdateIdle();
  bool _disposed = false;
  final _waiting = <Completer<UpdateCheck>>[];

  @override
  UpdateState get state => _state;

  /// Off until a backend learns to check by hand: no button beats one that
  /// pretends.
  @override
  bool get canCheck => false;

  @override
  Future<UpdateCheck> check() async => UpdateCheck.upToDate;

  /// Does nothing after [dispose]: downloads and platform calls finish
  /// whenever they finish, and may find the updater gone.
  @protected
  void move(UpdateState next) {
    if (_disposed) return;
    _state = next;
    if (_outcome(next) case final outcome?) _answer(outcome);
    notifyListeners();
  }

  /// How a check already under way ends: ready once something is staged,
  /// failed if it falls back to idle. Answers at once when it has ended.
  @protected
  Future<UpdateCheck> settled() {
    final now = _outcome(_state);
    if (now != null) return Future.value(now);
    final done = Completer<UpdateCheck>();
    _waiting.add(done);
    return done.future;
  }

  static UpdateCheck? _outcome(UpdateState state) => switch (state) {
    UpdateReady() || UpdateApplying() => UpdateCheck.ready,
    UpdateIdle() => UpdateCheck.failed,
    UpdatePreparing() => null,
  };

  void _answer(UpdateCheck outcome) {
    final waiting = [..._waiting];
    _waiting.clear();
    for (final done in waiting) {
      done.complete(outcome);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // Whoever was waiting is gone too, or about to be; don't leave them hung.
    _answer(UpdateCheck.failed);
    super.dispose();
  }
}
