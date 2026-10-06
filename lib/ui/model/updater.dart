/// How this copy of the app replaces itself with a newer one. The shell
/// reads this and nothing else: which platform mechanism stands behind it
/// (Sparkle, the Flatpak portal, our own for an AppImage) is `lib/update/`'s
/// business. Phones have none; the stores own their updates.
library;

import 'package:flutter/foundation.dart';

sealed class UpdateState {
  const UpdateState();
}

/// Nothing newer is known.
final class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

/// A newer build is being checked, fetched or verified. Not shown: there is
/// nothing to do about it yet.
final class UpdatePreparing extends UpdateState {
  const UpdatePreparing();
}

/// Staged and verified on disk. [version] is null when the platform only
/// knows that something newer is there.
final class UpdateReady extends UpdateState {
  const UpdateReady(this.version);
  final String? version;
}

/// The restart was asked for and cannot be stopped.
final class UpdateApplying extends UpdateState {
  const UpdateApplying(this.version);
  final String? version;
}

/// How a check asked for by hand came out.
enum UpdateCheck { upToDate, ready, failed }

abstract class Updater implements Listenable {
  UpdateState get state;

  /// Whether [check] means anything. False where nothing updates this copy,
  /// so the about section offers no button that would do nothing.
  bool get canCheck;

  /// Looks now rather than on the schedule, and fetches whatever it finds.
  /// Completes once there is an answer: [UpdateCheck.ready] means
  /// [state] is [UpdateReady].
  Future<UpdateCheck> check();

  /// Restarts into the staged build. Only means anything in [UpdateReady].
  Future<void> restart();

  void dispose();
}

/// A copy of the app that nothing updates: a debug build, a phone, a
/// platform with no backend yet.
class NoUpdater implements Updater {
  const NoUpdater();

  @override
  UpdateState get state => const UpdateIdle();

  @override
  bool get canCheck => false;

  @override
  Future<UpdateCheck> check() async => UpdateCheck.upToDate;

  @override
  Future<void> restart() async {}

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  void dispose() {}
}

/// Says whatever it is told to, for tests and the mock.
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
  Future<void> restart() async {
    restarts++;
    state = const UpdateIdle();
  }
}
