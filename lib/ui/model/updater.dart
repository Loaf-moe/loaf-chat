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

abstract class Updater implements Listenable {
  UpdateState get state;

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
