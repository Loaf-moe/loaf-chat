/// This device's membership of a room's call: the state event that says it
/// is in, kept alive while it is, and emptied when it leaves. Written the
/// way Element Call writes its own.
library;

import 'dart:async';

import 'package:matrix/matrix.dart';

import 'call_members.dart';

/// When a membership is written again, and how long a failed write waits.
class CallMembershipTimings {
  const CallMembershipTimings({
    this.expiry = const Duration(hours: 4),
    this.refreshEvery = const Duration(hours: 1),
    this.headroom = const Duration(seconds: 5),
    this.retryRefreshIn = const Duration(minutes: 1),
    this.retryLeaveIn = const Duration(seconds: 2),
  });

  /// How much longer each write says the membership lasts.
  final Duration expiry;
  final Duration refreshEvery;

  /// How far ahead of [refreshEvery] a refresh is sent.
  final Duration headroom;
  final Duration retryRefreshIn;
  final Duration retryLeaveIn;

  /// When refresh number [n] is due for a membership that began at [joined].
  DateTime refreshAt(DateTime joined, int n) =>
      joined.add(refreshEvery * n).subtract(headroom);
}

/// The state key of this device's call membership in [room].
String callMemberStateKey(Client client, Room room) {
  final key = '${client.userID}_${client.deviceID}_m.call';
  final version = room.roomVersion ?? '';
  // MSC3757 rooms let a user own state keys that begin with their id.
  return version.startsWith('org.matrix.msc3757') ||
          version.startsWith('org.matrix.msc3779')
      ? key
      : '_$key';
}

class OwnCallMembership {
  OwnCallMembership(
    this._client,
    this._room,
    this._server, {
    DateTime Function()? now,
    this.timings = const CallMembershipTimings(),
    this.onLost,
  }) : _now = now ?? DateTime.now;

  final Client _client;
  final Room _room;
  final Uri _server;
  final DateTime Function() _now;
  final CallMembershipTimings timings;

  /// Called when the server refuses to keep the membership alive.
  final void Function()? onLost;

  static const _leaveAttempts = 3;

  Timer? _timer;
  DateTime? _joined;

  /// Whether the server may hold a membership of this device's: a write
  /// went out and was not refused.
  var _written = false;

  /// Done when the write before has been answered, so that writes reach
  /// the server in the order they were made. Never fails.
  Future<void> _writing = Future.value();

  String get stateKey => callMemberStateKey(_client, _room);

  /// Says this device is in the call.
  Future<void> join() async {
    _written = true;
    try {
      await _write(_content(1, created: null));
    } on MatrixException {
      // Refused: nothing was stored.
      _written = false;
      rethrow;
    }
    final joined = _joined = _now();
    _schedule(1, timings.refreshAt(joined, 1).difference(joined));
  }

  /// Says this device has left. Gives up after a few failed tries; the
  /// membership then runs out by itself.
  Future<void> leave() async {
    _timer?.cancel();
    _joined = null;
    if (!_written) return;
    _written = false;
    for (var attempt = 1; ; attempt++) {
      try {
        await _write(const {});
        return;
      } on MatrixException catch (e) {
        // Refused: asking again would be refused again.
        if (e.error != MatrixError.M_LIMIT_EXCEEDED) return;
      } on Exception {
        // A dropped connection, or a 5xx, which the SDK throws bare.
      }
      if (attempt == _leaveAttempts) return;
      await Future<void>.delayed(timings.retryLeaveIn);
    }
  }

  void dispose() => _timer?.cancel();

  void _schedule(int n, Duration after) {
    _timer?.cancel();
    _timer = Timer(after, () => unawaited(_refresh(n)));
  }

  Future<void> _refresh(int n) async {
    final joined = _joined;
    if (joined == null) return;
    try {
      await _write(_content(n + 1, created: _created(joined)));
    } on MatrixException catch (e) {
      if (e.error != MatrixError.M_LIMIT_EXCEEDED) {
        _joined = null;
        onLost?.call();
        return;
      }
      if (_joined != null) _schedule(n, timings.retryRefreshIn);
      return;
    } on Exception {
      // A dropped connection, or a 5xx, which the SDK throws bare.
      if (_joined != null) _schedule(n, timings.retryRefreshIn);
      return;
    }
    if (_joined == null) return;
    final due = timings.refreshAt(joined, n + 1).difference(_now());
    _schedule(n + 1, due.isNegative ? Duration.zero : due);
  }

  /// When the membership began: the server's time on the first write once a
  /// sync has brought it back, else when [join] returned.
  int _created(DateTime joined) {
    final own = _room.getState(callMemberType, stateKey);
    if (own is Event && own.content['application'] == 'm.call') {
      final created = own.content['created_ts'];
      return created is num
          ? created.toInt()
          : own.originServerTs.millisecondsSinceEpoch;
    }
    return joined.millisecondsSinceEpoch;
  }

  Map<String, Object?> _content(int writes, {required int? created}) => {
    'application': 'm.call',
    'call_id': '',
    'scope': 'm.room',
    'device_id': _client.deviceID,
    'membershipID': '${_client.userID}:${_client.deviceID}',
    'expires': timings.expiry.inMilliseconds * writes,
    'm.call.intent': 'audio',
    'focus_active': {'type': 'livekit', 'focus_selection': 'multi_sfu'},
    'foci_preferred': [
      {
        'type': 'livekit',
        'livekit_service_url': _server.toString(),
        'livekit_alias': _room.id,
      },
    ],
    'created_ts': ?created,
  };

  Future<void> _write(Map<String, Object?> content) async {
    final before = _writing;
    final answered = Completer<void>();
    _writing = answered.future;
    await before;
    try {
      await _client.setRoomStateWithKey(
        _room.id,
        callMemberType,
        stateKey,
        content,
      );
    } finally {
      answered.complete();
    }
  }
}
