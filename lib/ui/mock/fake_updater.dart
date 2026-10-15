/// An updater that says whatever it is told to, for tests and the mock.
library;

import 'package:flutter/foundation.dart';

import '../../update/updater.dart';

class FakeUpdater extends ChangeNotifier implements Updater {
  FakeUpdater([this._state = const UpdateIdle()]);

  UpdateState _state;
  int restarts = 0;
  int checks = 0;

  /// What the next [check] answers. Ready moves [state] to [UpdateReady].
  UpdateCheck nextCheck = UpdateCheck.upToDate;
  String? nextVersion = '0.3.0';

  /// How long a check takes. The mock waits, so "checking…" is seen.
  Duration checkTakes = Duration.zero;

  @override
  bool get canCheck => true;

  @override
  Future<UpdateCheck> check() async {
    checks++;
    if (checkTakes > Duration.zero) {
      state = const UpdatePreparing();
      await Future<void>.delayed(checkTakes);
      if (nextCheck != UpdateCheck.ready) state = const UpdateIdle();
    }
    if (nextCheck == UpdateCheck.ready) state = UpdateReady(nextVersion);
    return nextCheck;
  }

  @override
  UpdateState get state => _state;

  set state(UpdateState value) {
    _state = value;
    notifyListeners();
  }

  /// As if the app had restarted: the notice has nothing left to say.
  @override
  Future<void> restart(UpdateReady ready) async {
    restarts++;
    state = const UpdateIdle();
  }
}
