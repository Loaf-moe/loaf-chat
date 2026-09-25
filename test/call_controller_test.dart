import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/call/call_controller.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';

const _me = Member('@me', 'me', Colors.red);
const _ana = Member('@ana', 'Ana', Colors.blue);
const _bo = Member('@bo', 'Bo', Colors.green);
const _cy = Member('@cy', 'Cy', Colors.orange);

const _lounge = Channel(
  id: 'lounge',
  name: 'lounge',
  kind: ChannelKind.voice,
  occupants: [_ana, _bo],
);
const _den = Channel(id: 'den', name: 'den', kind: ChannelKind.voice);
const _dmAna = Channel(
  id: 'dm-ana',
  name: 'Ana',
  kind: ChannelKind.direct,
  members: [_ana],
);
const _group = Channel(
  id: 'dm-group',
  name: 'crew',
  kind: ChannelKind.direct,
  members: [_ana, _bo, _cy],
);

/// Widget tests dispose their controller as their last line rather than in a
/// tear-down: the binding checks for pending timers before tear-downs run.
///
/// A controller whose clock the test moves by hand, since fake async time
/// does not move DateTime.now().
({
  CallController calls,
  List<(String, CallRecord)> records,
  void Function(Duration) advance,
})
_controller({Map<String, RingBehaviour> rings = const {}}) {
  var now = DateTime(2026, 9, 24, 20);
  final records = <(String, CallRecord)>[];
  final calls = CallController(
    me: _me,
    rings: rings,
    now: () => now,
    onRecord: (dm, record) => records.add((dm.id, record)),
  );
  return (calls: calls, records: records, advance: (d) => now = now.add(d));
}

void main() {
  group('voice channels', () {
    testWidgets('connect, then go live with whoever is there', (tester) async {
      final (:calls, records: _, advance: _) = _controller();

      calls.joinVoice(_lounge, spaceName: 'Home Bakery');
      expect(calls.session!.phase, CallPhase.connecting);
      expect(calls.session!.spaceName, 'Home Bakery');

      await tester.pump(CallController.connectDelay);
      expect(calls.session!.phase, CallPhase.live);
      expect(calls.session!.participants.map((p) => p.member), [_ana, _bo]);
      calls.dispose();
    });

    testWidgets('joining another call silently drops this one', (tester) async {
      final (:calls, records: _, advance: _) = _controller();

      calls.joinVoice(_lounge, spaceName: 's');
      await tester.pump(CallController.connectDelay);
      calls.joinVoice(_den, spaceName: 's');

      expect(calls.session!.target.id, 'den');
      calls.dispose();
    });

    testWidgets('a failed connection can be retried', (tester) async {
      final (:calls, records: _, advance: _) = _controller();

      calls.failNextConnection();
      calls.joinVoice(_lounge, spaceName: 's');
      await tester.pump(CallController.connectDelay);
      expect(calls.session!.phase, CallPhase.failed);

      calls.retry();
      await tester.pump(CallController.connectDelay);
      expect(calls.session!.phase, CallPhase.live);
      calls.dispose();
    });

    test('voice channels never record anything', () {
      final (:calls, :records, advance: _) = _controller();
      addTearDown(calls.dispose);

      calls.joinVoice(_lounge, spaceName: 's');
      calls.leave();

      expect(calls.session, isNull);
      expect(records, isEmpty);
    });
  });

  group('your own audio', () {
    test('deafening implies muting, and undeafening restores both', () {
      final (:calls, records: _, advance: _) = _controller();
      addTearDown(calls.dispose);

      calls.toggleDeafen();
      expect(calls.deafened, isTrue);
      expect(calls.muted, isTrue);

      calls.toggleDeafen();
      expect(calls.deafened, isFalse);
      expect(calls.muted, isFalse);
    });

    test('unmuting while deafened undeafens too', () {
      final (:calls, records: _, advance: _) = _controller();
      addTearDown(calls.dispose);

      calls.toggleDeafen();
      calls.toggleMute();

      expect(calls.muted, isFalse);
      expect(calls.deafened, isFalse);
    });
  });

  group('calling a 1:1 DM', () {
    testWidgets('rings, then goes live when they answer', (tester) async {
      final (:calls, records: _, advance: _) = _controller(
        rings: {'@ana': const RingBehaviour.answer(Duration(seconds: 3))},
      );

      calls.startDirect(_dmAna);
      expect(calls.session!.phase, CallPhase.ringing);
      expect(calls.session!.participants.single.ring, RingState.ringing);

      await tester.pump(const Duration(seconds: 3));
      expect(calls.session!.phase, CallPhase.live);
      expect(calls.session!.participants.single.ring, RingState.joined);
      calls.dispose();
    });

    testWidgets('a video call starts with your camera on', (tester) async {
      final (:calls, records: _, advance: _) = _controller();

      calls.startDirect(_dmAna, video: true);
      expect(calls.camera, isTrue);
      calls.dispose();
    });

    testWidgets('declining ends it and leaves a missed call', (tester) async {
      final (:calls, :records, advance: _) = _controller(
        rings: {'@ana': const RingBehaviour.decline(Duration(seconds: 2))},
      );

      calls.startDirect(_dmAna);
      await tester.pump(const Duration(seconds: 2));

      expect(calls.session!.phase, CallPhase.declined);
      expect(records.single.$1, 'dm-ana');
      expect(records.single.$2.label, 'missed call');
      calls.dispose();
    });

    testWidgets('nobody answering for 30 seconds is a missed call', (
      tester,
    ) async {
      final (:calls, :records, advance: _) = _controller();

      calls.startDirect(_dmAna);
      await tester.pump(CallController.ringTimeout);

      expect(calls.session!.phase, CallPhase.unanswered);
      expect(calls.session!.participants.single.ring, RingState.noAnswer);
      expect(records.single.$2.label, 'missed call');
      calls.dispose();
    });

    testWidgets('call again rings once more', (tester) async {
      final (:calls, records: _, advance: _) = _controller();

      calls.startDirect(_dmAna);
      await tester.pump(CallController.ringTimeout);
      calls.callAgain();

      expect(calls.session!.phase, CallPhase.ringing);
      await tester.pump(CallController.ringTimeout);
      calls.dispose();
    });

    testWidgets('hanging up a live call records how long it lasted', (
      tester,
    ) async {
      final (:calls, :records, :advance) = _controller(
        rings: {'@ana': const RingBehaviour.answer(Duration(seconds: 1))},
      );

      calls.startDirect(_dmAna);
      await tester.pump(const Duration(seconds: 1));
      advance(const Duration(minutes: 12));
      calls.leave();

      expect(calls.session, isNull);
      expect(records.single.$2.label, 'call · 12m');
      calls.dispose();
    });
  });

  group('calling a group DM', () {
    testWidgets('goes live on the first answer and tracks everyone else', (
      tester,
    ) async {
      final (:calls, :records, advance: _) = _controller(
        rings: {
          '@ana': const RingBehaviour.answer(Duration(seconds: 3)),
          '@bo': const RingBehaviour.decline(Duration(seconds: 2)),
        },
      );

      calls.startDirect(_group);
      await tester.pump(const Duration(seconds: 2));
      expect(calls.session!.phase, CallPhase.ringing);
      expect(calls.session!.find('@bo')!.ring, RingState.declined);

      await tester.pump(const Duration(seconds: 1));
      expect(calls.session!.phase, CallPhase.live);

      await tester.pump(CallController.ringTimeout);
      expect(calls.session!.phase, CallPhase.live);
      expect(calls.session!.find('@cy')!.ring, RingState.noAnswer);
      expect(records, isEmpty);
      calls.dispose();
    });

    testWidgets('nobody answering says so', (tester) async {
      final (:calls, :records, advance: _) = _controller(
        rings: {'@bo': const RingBehaviour.decline(Duration(seconds: 2))},
      );

      calls.startDirect(_group);
      await tester.pump(CallController.ringTimeout);

      expect(calls.session!.phase, CallPhase.unanswered);
      expect(records.single.$2.label, 'no one answered');
      calls.dispose();
    });
  });

  group('an incoming ring', () {
    testWidgets('accepting drops your current call and joins theirs', (
      tester,
    ) async {
      final (:calls, records: _, advance: _) = _controller();

      calls.joinVoice(_lounge, spaceName: 's');
      calls.receive(_dmAna, from: _ana);
      expect(calls.incoming!.caller, _ana);

      calls.accept();
      expect(calls.incoming, isNull);
      expect(calls.session!.target.id, 'dm-ana');

      await tester.pump(CallController.connectDelay);
      expect(calls.session!.phase, CallPhase.live);
      expect(calls.session!.find('@ana')!.ring, RingState.joined);
      calls.dispose();
    });

    testWidgets('declining just stops the ring', (tester) async {
      final (:calls, :records, advance: _) = _controller();

      calls.receive(_dmAna, from: _ana);
      calls.decline();

      expect(calls.incoming, isNull);
      expect(calls.session, isNull);
      await tester.pump(CallController.ringTimeout);
      expect(records, isEmpty);
      calls.dispose();
    });

    testWidgets('ringing out is a missed call', (tester) async {
      final (:calls, :records, advance: _) = _controller();

      calls.receive(_dmAna, from: _ana);
      await tester.pump(CallController.ringTimeout);

      expect(calls.incoming, isNull);
      expect(records.single.$2.label, 'missed call');
      calls.dispose();
    });
  });

  group('the spotlight', () {
    testWidgets('goes to the newest screen share unless someone is pinned', (
      tester,
    ) async {
      final (:calls, records: _, advance: _) = _controller();

      calls.joinVoice(_lounge, spaceName: 's');
      await tester.pump(CallController.connectDelay);
      expect(calls.spotlight, isNull);

      calls.toggleRemoteShare('@ana');
      calls.toggleRemoteShare('@bo');
      expect(calls.spotlight, '@bo');

      calls.pin('@ana');
      expect(calls.spotlight, '@ana');

      calls.pin(null);
      calls.toggleRemoteShare('@bo');
      expect(calls.spotlight, '@ana');
      calls.dispose();
    });

    testWidgets('your own share counts too', (tester) async {
      final (:calls, records: _, advance: _) = _controller();

      calls.joinVoice(_lounge, spaceName: 's');
      calls.startScreenShare('Entire screen');

      expect(calls.sharing, 'Entire screen');
      expect(calls.spotlight, '@me');
      calls.dispose();
    });
  });
}
