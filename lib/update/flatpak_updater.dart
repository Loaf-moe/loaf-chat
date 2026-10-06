/// Updates a Flatpak through the portal: the system does the fetching,
/// verifying and installing, and this only follows along.
library;

import 'dart:async';
import 'dart:io';

import '../ui/model/updater.dart';
import 'flatpak_portal.dart';
import 'state_updater.dart';
import 'update_log.dart';

class FlatpakUpdater extends StateUpdater {
  FlatpakUpdater({
    required this.portal,
    required this.version,
    void Function()? quit,
  }) : _quit = quit ?? (() => exit(0));

  final FlatpakPortal portal;

  /// The newest release's version name, from the feed: the portal speaks in
  /// commits. Null, or a throw, means the notice goes without one.
  final Future<String?> Function() version;
  final void Function() _quit;

  StreamSubscription<UpdateCommits>? _watching;

  /// Update monitors arrived in version 2 of the portal (flatpak 1.5).
  static const _monitors = 2;

  Future<void> start() async {
    try {
      if (await portal.version() < _monitors) return;
    } catch (e) {
      updateLog('no Flatpak portal; the software centre updates this', e);
      return;
    }
    _watching = portal.watch().listen(
      _onCommits,
      onError: (Object e, StackTrace s) => updateLog('the portal', e, s),
    );
    // The about section's button can mean something now.
    notifyListeners();
  }

  @override
  bool get canCheck => _watching != null;

  /// The portal keeps its own schedule; asking it to update is how to look
  /// sooner. It says when there is nothing to install.
  @override
  Future<UpdateCheck> check() async {
    if (state is! UpdateIdle) return settled();
    move(const UpdatePreparing());
    try {
      if (!await portal.update()) {
        move(const UpdateIdle());
        return UpdateCheck.upToDate;
      }
      move(UpdateReady(await _version()));
      return UpdateCheck.ready;
    } catch (e, s) {
      updateLog('the Flatpak was not updated', e, s);
      move(const UpdateIdle());
      return UpdateCheck.failed;
    }
  }

  Future<void> _onCommits(UpdateCommits commits) async {
    // Said again mid-install, or once it is ready: already in hand.
    if (state is! UpdateIdle) return;
    if (commits.local != commits.running) {
      // The system got there first.
      move(const UpdatePreparing());
      move(UpdateReady(await _version()));
    } else if (commits.remote != commits.local) {
      move(const UpdatePreparing());
      try {
        move(
          await portal.update()
              ? UpdateReady(await _version())
              : const UpdateIdle(),
        );
      } catch (e, s) {
        updateLog('the Flatpak was not updated', e, s);
        move(const UpdateIdle());
      }
    }
  }

  Future<String?> _version() async {
    try {
      return await version();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> restart() async {
    final ready = state;
    if (ready is! UpdateReady) return;
    move(UpdateApplying(ready.version));
    try {
      await portal.spawnLatest();
    } catch (e, s) {
      updateLog('the new Flatpak did not start', e, s);
      move(ready);
      return;
    }
    _quit();
  }

  @override
  void dispose() {
    unawaited(_watching?.cancel());
    unawaited(portal.close());
    super.dispose();
  }
}
