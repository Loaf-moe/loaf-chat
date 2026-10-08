import 'dart:async';

/// The rooms waiting to be counted from the server's history, and how many
/// are asked at once. A room whose fetch failed keeps its old count and is
/// tried again, but with a wait that grows, so a server that can't answer
/// isn't asked afresh by every sync.
class UnreadFills {
  UnreadFills(this._fill, {this.onSettled, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// Fetches one room. False when it failed and should be tried again.
  final Future<bool> Function(String roomId) _fill;
  final DateTime Function() _now;

  /// Called when a room's fetch ends, worked or failed, and no further one
  /// is waiting for it. For work that had to wait for the room to be free.
  final void Function(String roomId)? onSettled;

  /// At most this many rooms fetch at once, so a launch with many unread
  /// rooms doesn't fire every request together.
  static const _parallelFills = 4;

  /// The wait after a first failure; each one in a row doubles it, to
  /// [_longestWait].
  static const _firstWait = Duration(seconds: 30);
  static const _longestWait = Duration(minutes: 10);

  final _filling = <String>{};
  final _queue = <String>[];

  /// Rooms that needed a fill again while one was already out: a gap, or
  /// your own message, that the fetch in flight may have missed.
  final _refill = <String>{};

  /// Rooms whose last fill failed, with when the sweep may try them again
  /// and the wait that follows if that fails too.
  final _failed = <String, ({DateTime retryAt, Duration wait})>{};
  var _disposed = false;

  /// Whether [roomId] is being fetched now.
  bool isFilling(String roomId) => _filling.contains(roomId);

  /// Asks for [roomId] to be filled, or filled again if a fetch is out. Not
  /// held back by a failure's wait: a gap, a seed or your own message is
  /// news the failed fetch never saw.
  void schedule(String roomId) {
    if (_filling.contains(roomId)) {
      _refill.add(roomId);
      return;
    }
    if (_queue.contains(roomId)) return;
    _queue.add(roomId);
    _pump();
  }

  /// Tries the failed rooms whose wait is over, now the server answers
  /// syncs again. Only those: a room mid-fill would otherwise be asked for
  /// again by every sync that lands, and never finish.
  void retryFailed() {
    final now = _now();
    for (final MapEntry(key: roomId, value: failure) in [..._failed.entries]) {
      if (now.isBefore(failure.retryAt)) continue;
      if (!_filling.contains(roomId) && !_queue.contains(roomId)) {
        schedule(roomId);
      }
    }
  }

  /// [roomId] is gone: whatever it had waiting goes with it.
  void forget(String roomId) {
    _failed.remove(roomId);
    _queue.remove(roomId);
    _refill.remove(roomId);
  }

  /// Stops starting fetches. Those out finish, but nothing follows them.
  void dispose() => _disposed = true;

  void _pump() {
    while (!_disposed &&
        _filling.length < _parallelFills &&
        _queue.isNotEmpty) {
      final roomId = _queue.removeAt(0);
      _filling.add(roomId);
      unawaited(
        _run(roomId).whenComplete(() {
          _filling.remove(roomId);
          if (_refill.remove(roomId)) {
            _queue.add(roomId);
          } else {
            onSettled?.call(roomId);
          }
          _pump();
        }),
      );
    }
  }

  /// Fetches [roomId] and keeps the books on how it went. The wait counts
  /// failed attempts in a row, however each began: a refill or a fresh
  /// schedule that fails doubles it too, since a room failing fast is
  /// failing.
  Future<void> _run(String roomId) async {
    final ok = await _fill(roomId);
    if (ok) {
      _failed.remove(roomId);
      return;
    }
    final last = _failed[roomId]?.wait;
    final wait = last == null
        ? _firstWait
        : (last * 2 > _longestWait ? _longestWait : last * 2);
    _failed[roomId] = (retryAt: _now().add(wait), wait: wait);
  }
}
