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
    this.expiry = const Duration(minutes: 10),
    this.refreshEvery = const Duration(minutes: 5),
    this.headroom = const Duration(seconds: 5),
    this.retryRefreshIn = const Duration(seconds: 15),
    this.retryLeaveIn = const Duration(seconds: 2),
  });

  /// How long a membership lasts past the write that last refreshed it. A
  /// device that dies without leaving stays listed this long.
  final Duration expiry;
  final Duration refreshEvery;

  /// How far ahead of [refreshEvery] a refresh is sent.
  final Duration headroom;
  final Duration retryRefreshIn;
  final Duration retryLeaveIn;

  /// How long after a write the next refresh is sent.
  Duration get refreshAfter => refreshEvery - headroom;
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
      await _write(_content(Duration.zero, created: null));
    } on MatrixException {
      // Refused: nothing was stored.
      _written = false;
      rethrow;
    }
    _joined = _now();
    _schedule(timings.refreshAfter);
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

  void _schedule(Duration after) {
    _timer?.cancel();
    _timer = Timer(after, () => unawaited(_refresh()));
  }

  Future<void> _refresh() async {
    final joined = _joined;
    if (joined == null) return;
    try {
      await _write(
        _content(_now().difference(joined), created: _created(joined)),
      );
    } on MatrixException catch (e) {
      if (e.error != MatrixError.M_LIMIT_EXCEEDED) {
        _joined = null;
        onLost?.call();
        return;
      }
      if (_joined != null) _schedule(timings.retryRefreshIn);
      return;
    } on Exception {
      // A dropped connection, or a 5xx, which the SDK throws bare.
      if (_joined != null) _schedule(timings.retryRefreshIn);
      return;
    }
    if (_joined != null) _schedule(timings.refreshAfter);
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

  /// What this device writes [since] the membership began. Its `expires`
  /// counts from that beginning, so it is always one expiry from now: not
  /// Element Call's whole expiry per refresh, which runs further ahead of
  /// the clock each time.
  Map<String, Object?> _content(Duration since, {required int? created}) => {
    'application': 'm.call',
    'call_id': '',
    'scope': 'm.room',
    'device_id': _client.deviceID,
    'membershipID': '${_client.userID}:${_client.deviceID}',
    'expires': (since + timings.expiry).inMilliseconds,
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
