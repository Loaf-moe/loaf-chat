import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/unread_fills.dart';

/// Fills that wait for the test to answer them, and a clock it moves.
class _Rig {
  _Rig() {
    fills = UnreadFills(_fill, now: () => clock);
  }

  late final UnreadFills fills;
  var clock = DateTime(2030);
  final started = <String>[];
  final _open = <String, Completer<bool>>{};

  Future<bool> _fill(String roomId) {
    started.add(roomId);
    return (_open[roomId] = Completer<bool>()).future;
  }

  /// Answers [roomId]'s fetch in flight: true when it worked.
  Future<void> finish(String roomId, {bool ok = true}) async {
    _open.remove(roomId)!.complete(ok);
    await Future<void>.delayed(Duration.zero);
  }

  void pass(Duration time) => clock = clock.add(time);

  int get fetching => _open.length;
}

void main() {
  test('at most four rooms fetch at once; the rest wait their turn', () async {
    final rig = _Rig();
    for (final id in ['a', 'b', 'c', 'd', 'e', 'f']) {
      rig.fills.schedule(id);
    }
    expect(rig.started, ['a', 'b', 'c', 'd']);
    await rig.finish('b');
    expect(rig.started, ['a', 'b', 'c', 'd', 'e']);
    await rig.finish('a');
    expect(rig.started.last, 'f');
    expect(rig.fetching, 4);
  });

  test('a room scheduled mid-flight fetches again once it lands', () async {
    final rig = _Rig();
    rig.fills.schedule('a');
    rig.fills.schedule('a');
    expect(rig.started, ['a']);
    expect(rig.fills.isFilling('a'), isTrue);
    await rig.finish('a');
    expect(rig.started, ['a', 'a']);
    await rig.finish('a');
    expect(rig.started, ['a', 'a']);
    expect(rig.fills.isFilling('a'), isFalse);
  });

  test('a failed room waits 30 seconds before the sweep retries it', () async {
    final rig = _Rig();
    rig.fills.schedule('a');
    await rig.finish('a', ok: false);
    rig.fills.retryFailed();
    expect(rig.started, ['a']);
    rig.pass(const Duration(seconds: 29));
    rig.fills.retryFailed();
    expect(rig.started, ['a']);
    rig.pass(const Duration(seconds: 1));
    rig.fills.retryFailed();
    expect(rig.started, ['a', 'a']);
  });

  test('each failure in a row doubles the wait, up to ten minutes', () async {
    final rig = _Rig();
    rig.fills.schedule('a');
    for (final wait in [30, 60, 120, 240, 480, 600, 600]) {
      await rig.finish('a', ok: false);
      final tries = rig.started.length;
      rig.pass(Duration(seconds: wait - 1));
      rig.fills.retryFailed();
      expect(rig.started.length, tries, reason: 'still waiting $wait s');
      rig.pass(const Duration(seconds: 1));
      rig.fills.retryFailed();
      expect(rig.started.length, tries + 1, reason: 'retries at $wait s');
    }
  });

  test('a fill that works clears the wait', () async {
    final rig = _Rig();
    rig.fills.schedule('a');
    await rig.finish('a', ok: false);
    rig.pass(const Duration(seconds: 30));
    rig.fills.retryFailed();
    await rig.finish('a', ok: false); // Now waits 60 s.
    rig.pass(const Duration(seconds: 60));
    rig.fills.retryFailed();
    await rig.finish('a'); // Works.
    rig.fills.retryFailed();
    expect(rig.started.length, 3, reason: 'nothing left to retry');
    // Failing again starts over at 30 s.
    rig.fills.schedule('a');
    await rig.finish('a', ok: false);
    rig.pass(const Duration(seconds: 30));
    rig.fills.retryFailed();
    expect(rig.started.length, 5);
  });

  test('a fresh schedule goes ahead of the wait', () async {
    final rig = _Rig();
    rig.fills.schedule('a');
    await rig.finish('a', ok: false);
    rig.fills.schedule('a');
    expect(rig.started, ['a', 'a']);
  });

  test('forgetting a room drops its failure, its place and its wait', () async {
    final rig = _Rig();
    rig.fills.schedule('a');
    await rig.finish('a', ok: false);
    rig.fills.forget('a');
    rig.pass(const Duration(hours: 1));
    rig.fills.retryFailed();
    expect(rig.started, ['a']);

    // Queued behind four others, it never starts.
    for (final id in ['b', 'c', 'd', 'e', 'x']) {
      rig.fills.schedule(id);
    }
    rig.fills.forget('x');
    await rig.finish('b');
    expect(rig.started, ['a', 'b', 'c', 'd', 'e']);
  });

  test('the sweep leaves a room that is fetching or queued alone', () async {
    final rig = _Rig();
    rig.fills.schedule('a');
    await rig.finish('a', ok: false);
    rig.pass(const Duration(minutes: 1));
    rig.fills.retryFailed();
    rig.fills.retryFailed();
    expect(rig.started, ['a', 'a']);
  });
}
