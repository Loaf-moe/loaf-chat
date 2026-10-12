import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/call/call_audio_hold.dart';
import 'package:loaf_native/ui/call/calls.dart';
import 'package:loaf_native/ui/model/models.dart';

import 'voice_only_calls.dart';

const _oven = Channel(id: '!oven', name: 'oven', kind: ChannelKind.voice);

CallSession _call(CallPhase phase) =>
    CallSession(target: _oven, phase: phase, participants: const []);

void main() {
  late VoiceOnlyCalls calls;
  late List<bool> told;

  CallAudioHold hold() {
    final hold = CallAudioHold(calls, hold: told.add);
    addTearDown(hold.dispose);
    return hold;
  }

  setUp(() {
    calls = VoiceOnlyCalls();
    addTearDown(calls.dispose);
    told = [];
  });

  test('a call beginning holds the audio', () {
    hold();

    calls.show(_call(CallPhase.connecting));

    expect(told, [true]);
  });

  test('a call changing while it lasts says nothing more', () {
    hold();
    calls.show(_call(CallPhase.connecting));

    calls.show(_call(CallPhase.live));
    calls.show(_call(CallPhase.reconnecting));

    expect(told, [true]);
  });

  test('a call ending lets the audio go', () {
    hold();
    calls.show(_call(CallPhase.live));

    calls.show(null);

    expect(told, [true, false]);
  });

  test('a call already under way holds the audio from the start', () {
    calls.show(_call(CallPhase.live));

    hold();

    expect(told, [true]);
  });
}
