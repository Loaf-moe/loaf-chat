/// How this copy of the app replaces itself with a newer one. The shell
/// reads this and nothing else: which platform mechanism stands behind it
/// (Sparkle, the Flatpak portal, our own for an AppImage) is the business
/// of the platform folders beside this file. Phones have none; the stores
/// own their updates.
library;

import 'package:flutter/foundation.dart';

sealed class UpdateState {
  const UpdateState();

  /// Whether a newer build is on disk, ready or already being restarted
  /// into. A check then has nothing left to find.
  bool get staged => switch (this) {
    UpdateReady() || UpdateApplying() => true,
    UpdateIdle() || UpdatePreparing() => false,
  };
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

  /// Restarts into the build [ready] names, which is the [state] read a
  /// moment ago: taking it means nothing can ask for a restart with nothing
  /// staged. If [state] has moved on since, this does nothing.
  Future<void> restart(UpdateReady ready);

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
  Future<void> restart(UpdateReady ready) async {}

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  void dispose() {}
}
