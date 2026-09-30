/// [Devices] over the SDK: the account's sessions, renaming them, and
/// signing one out behind the server's check of who you are.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ui/settings/devices.dart';
import '../ui/verify/verifier.dart';
import 'matrix_reauth.dart';

class MatrixDevices extends ChangeNotifier implements Devices {
  MatrixDevices(this.client, {Future<bool> Function(Uri url)? openBrowser})
    : _openBrowser = openBrowser ?? _launch {
    // Another of your devices signing in or out shows up as a change to
    // your own device list; nothing here polls.
    _sync = client.onSync.stream.listen((update) {
      final me = client.userID;
      if (me != null && update.deviceLists?.changed?.contains(me) == true) {
        unawaited(_reload());
      }
    });
  }

  final Client client;
  final Future<bool> Function(Uri url) _openBrowser;
  late final StreamSubscription<SyncUpdate> _sync;
  var _disposed = false;

  /// Counts loads, so a slow older one can't put back what a newer one
  /// replaced.
  var _turn = 0;

  List<LoafDevice>? _list;

  static Future<bool> _launch(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  @override
  List<LoafDevice>? get list => _list;

  @override
  Future<void> load() async {
    final turn = ++_turn;
    final devices = await client.getDevices() ?? const <Device>[];
    if (_disposed || turn != _turn) return;
    final mine = client.userDeviceKeys[client.userID]?.deviceKeys;
    _list = [
      for (final d in devices)
        LoafDevice(
          id: d.deviceId,
          name: d.displayName ?? d.deviceId,
          current: d.deviceId == client.deviceID,
          verified: mine?[d.deviceId]?.verified ?? false,
          lastSeen: d.lastSeenTs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(d.lastSeenTs!),
          lastIp: d.lastSeenIp,
        ),
    ];
    notifyListeners();
  }

  /// A reload nobody asked for: the list stays as it was if it fails.
  Future<void> _reload() async {
    try {
      await load();
    } on Object catch (e, s) {
      Logs().w("[loaf] couldn't reload devices", e, s);
    }
  }

  @override
  Future<void> rename(String id, String name) async {
    await client.updateDevice(id, displayName: name);
    if (_disposed) return;
    // The rename landed; a list that can't be fetched now is not a failed
    // rename, and the next load shows the new name.
    await _reload();
  }

  @override
  Future<bool> signOut(
    String id, {
    required void Function(AuthChallenge) onAuth,
  }) async {
    // Its own request, never handed to `onUiaRequest`: identity creation
    // listens there, and must not be handed this one.
    final done = Completer<bool>();
    var cancelled = false;
    var asked = 0;
    late final UiaRequest<void> uia;
    uia = UiaRequest<void>(
      request: (auth) => client.deleteDevice(id, auth: auth),
      // Only completes: answering from here would re-enter the request.
      onUpdate: (state) {
        switch (state) {
          case UiaRequestState.done:
            if (!done.isCompleted) done.complete(true);
          case UiaRequestState.fail:
            if (done.isCompleted) return;
            if (cancelled) {
              done.complete(false);
            } else {
              done.completeError(uia.error!);
            }
          case UiaRequestState.waitForUser:
            if (_disposed) {
              // Nobody is left to answer.
              cancelled = true;
              uia.cancel();
              return;
            }
            final kind = authKindFor(uia);
            if (kind == null) {
              // A check this app can't answer: the delete fails, and says so.
              Logs().w('[loaf] the server asked for ${uia.nextStages}');
              uia.cancel();
              return;
            }
            onAuth(
              MatrixChallenge(
                client,
                uia,
                kind,
                retry: asked++ > 0,
                onCancel: () => cancelled = true,
                openBrowser: _openBrowser,
              ),
            );
          case UiaRequestState.loading:
            break;
        }
      },
    );
    final ok = await done.future;
    if (ok && !_disposed) {
      // Gone at the server, so gone here even if the list can't be fetched.
      _list = _list?.where((d) => d.id != id).toList();
      notifyListeners();
      await _reload();
    }
    return ok;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sync.cancel());
    super.dispose();
  }
}
