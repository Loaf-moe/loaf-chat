/// [Devices] from fixtures: three made-up sessions, and a server that asks
/// for a password before it signs one out — mockup only.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../settings/devices.dart';
import '../verify/verifier.dart';

class MockDevices extends ChangeNotifier implements Devices {
  MockDevices();

  static const answerDelay = Duration(milliseconds: 300);

  var _disposed = false;

  List<LoafDevice>? _list = [
    LoafDevice(
      id: 'THISMAC',
      name: 'loaf on this mac',
      current: true,
      verified: true,
      lastSeen: DateTime.now(),
      lastIp: '203.0.113.7',
    ),
    LoafDevice(
      id: 'PHONE',
      name: 'element on phone',
      current: false,
      verified: true,
      lastSeen: DateTime.now().subtract(const Duration(hours: 2)),
      lastIp: '198.51.100.23',
    ),
    LoafDevice(
      id: 'UNKNOWN',
      name: 'unknown session',
      current: false,
      verified: false,
      lastSeen: DateTime.now().subtract(const Duration(days: 30)),
    ),
  ];

  @override
  List<LoafDevice>? get list => _list;

  @override
  Future<void> load() async {}

  @override
  Future<void> rename(String id, String name) async {
    await Future<void>.delayed(answerDelay);
    if (_disposed) return;
    _list = [
      for (final d in _list!)
        if (d.id == id)
          LoafDevice(
            id: d.id,
            name: name,
            current: d.current,
            verified: d.verified,
            lastSeen: d.lastSeen,
            lastIp: d.lastIp,
          )
        else
          d,
    ];
    notifyListeners();
  }

  @override
  Future<bool> signOut(
    String id, {
    required void Function(AuthChallenge) onAuth,
  }) {
    final done = Completer<bool>();
    void ask({required bool retry}) =>
        onAuth(_MockChallenge(this, id, done, ask, retry: retry));
    ask(retry: false);
    return done.future;
  }

  void _remove(String id) {
    if (_disposed) return;
    _list = [
      for (final d in _list!)
        if (d.id != id) d,
    ];
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _MockChallenge implements AuthChallenge {
  _MockChallenge(
    this._devices,
    this._id,
    this._done,
    this._ask, {
    required this.retry,
  });

  final MockDevices _devices;
  final String _id;
  final Completer<bool> _done;
  final void Function({required bool retry}) _ask;

  @override
  final bool retry;

  @override
  AuthKind get kind => AuthKind.password;

  void _answer({required bool ok}) {
    unawaited(
      Future<void>.delayed(MockDevices.answerDelay, () {
        if (_done.isCompleted) return;
        if (!ok) return _ask(retry: true);
        _devices._remove(_id);
        _done.complete(true);
      }),
    );
  }

  /// Any password will do: the mock has no account to check it against.
  @override
  void password(String password) => _answer(ok: password.isNotEmpty);

  @override
  void openBrowser() {}

  @override
  void browserFinished() => _answer(ok: true);

  @override
  void cancel() {
    if (!_done.isCompleted) _done.complete(false);
  }
}
