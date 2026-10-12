import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/call/call_sounds.dart';
import 'package:loaf_native/ui/call/calls.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/model/models.dart';

import 'voice_only_calls.dart';

const _oven = Channel(id: '!oven', name: 'oven', kind: ChannelKind.voice);
const _kiln = Channel(id: '!kiln', name: 'kiln', kind: ChannelKind.voice);

CallParticipant _someone(int n) =>
    CallParticipant(Member('@p$n:loaf.test', 'p$n', const Color(0xFF888888)));

/// A call, its sounds, and a clock the test moves.
class _Scene {
  _Scene({bool sound = true, CallSession? already}) {
    calls.session = already;
    sounds = CallSounds(calls, chime, soundOn: () => sound, elapsed: () => now);
    addTearDown(sounds.dispose);
    addTearDown(calls.dispose);
  }

  final calls = VoiceOnlyCalls();
  final chime = FakeChime();
  late final CallSounds sounds;
  var now = Duration.zero;

  /// Puts the call in [phase] with [others] people in it, a second later
  /// than the last change unless [after] says otherwise.
  void call(
    CallPhase phase, {
    int others = 0,
    Channel channel = _oven,
    Duration after = const Duration(seconds: 1),
  }) {
    now += after;
    calls.show(
      CallSession(
        target: channel,
        phase: phase,
        participants: [for (var n = 0; n < others; n++) _someone(n)],
      ),
    );
  }

  void gone() {
    now += const Duration(seconds: 1);
    calls.show(null);
  }
}

void main() {
  test('going live plays the join sound', () {
    final scene = _Scene()..call(CallPhase.connecting);

    scene.call(CallPhase.live);

    expect(scene.chime.played, [AppSound.callJoined]);
  });

  test('connecting plays nothing', () {
    final scene = _Scene();

    scene.call(CallPhase.connecting);

    expect(scene.chime.played, isEmpty);
  });

  test('leaving a live call plays the leave sound', () {
    final scene = _Scene()..call(CallPhase.live);

    scene.gone();

    expect(scene.chime.played.last, AppSound.callLeft);
  });

  test('leaving before the call went live plays nothing', () {
    final scene = _Scene()..call(CallPhase.connecting);

    scene.gone();

    expect(scene.chime.played, isEmpty);
  });

  test('a live call that fails plays the leave sound', () {
    final scene = _Scene()..call(CallPhase.live);

    scene.call(CallPhase.failed);

    expect(scene.chime.played.last, AppSound.callLeft);
  });

  test('a join that fails before going live plays nothing', () {
    final scene = _Scene()..call(CallPhase.connecting);

    scene.call(CallPhase.failed);

    expect(scene.chime.played, isEmpty);
  });

  test('joining another channel from a live call plays leave, then join', () {
    final scene = _Scene()..call(CallPhase.live);

    scene
      ..call(CallPhase.connecting, channel: _kiln)
      ..call(CallPhase.live, channel: _kiln);

    expect(scene.chime.played, [
      AppSound.callJoined,
      AppSound.callLeft,
      AppSound.callJoined,
    ]);
  });

  test('someone joining a live call plays the join sound', () {
    final scene = _Scene()..call(CallPhase.live);

    scene.call(CallPhase.live, others: 1);

    expect(scene.chime.played, [AppSound.callJoined, AppSound.callJoined]);
  });

  test('someone leaving a live call plays the leave sound', () {
    final scene = _Scene()..call(CallPhase.live, others: 2);

    scene.call(CallPhase.live, others: 1);

    expect(scene.chime.played, [AppSound.callJoined, AppSound.callLeft]);
  });

  test('the people already there when you join add nothing', () {
    final scene = _Scene()..call(CallPhase.connecting, others: 3);

    scene.call(CallPhase.live, others: 3);

    expect(scene.chime.played, [AppSound.callJoined]);
  });

  test('reconnecting, and coming back, plays nothing', () {
    final scene = _Scene()..call(CallPhase.live, others: 1);

    scene
      ..call(CallPhase.reconnecting, others: 1)
      ..call(CallPhase.live, others: 1);

    expect(scene.chime.played, [AppSound.callJoined]);
  });

  test('an eighth person joining, you included, plays the join sound', () {
    final scene = _Scene()..call(CallPhase.live, others: 6);

    scene.call(CallPhase.live, others: 7);

    expect(scene.chime.played, [AppSound.callJoined, AppSound.callJoined]);
  });

  test('a ninth person joining plays nothing', () {
    final scene = _Scene()..call(CallPhase.live, others: 7);

    scene.call(CallPhase.live, others: 8);

    expect(scene.chime.played, [AppSound.callJoined]);
  });

  test('someone leaving a call of more than eight plays nothing', () {
    final scene = _Scene()..call(CallPhase.live, others: 9);

    scene.call(CallPhase.live, others: 8);

    expect(scene.chime.played, [AppSound.callJoined]);
  });

  test('a call already live when the sounds start plays nothing', () {
    final scene = _Scene(
      already: const CallSession(
        target: _oven,
        phase: CallPhase.live,
        participants: [],
      ),
    );

    expect(scene.chime.played, isEmpty);
  });

  test('a call already live when the sounds start still sounds on leaving', () {
    final scene = _Scene(
      already: const CallSession(
        target: _oven,
        phase: CallPhase.live,
        participants: [],
      ),
    );

    scene.gone();

    expect(scene.chime.played, [AppSound.callLeft]);
  });

  test('two people joining within half a second play once', () {
    final scene = _Scene()..call(CallPhase.live);

    scene
      ..call(CallPhase.live, others: 1)
      ..call(
        CallPhase.live,
        others: 2,
        after: const Duration(milliseconds: 499),
      );

    expect(scene.chime.played, [AppSound.callJoined, AppSound.callJoined]);
  });

  test('two people joining half a second apart play twice', () {
    final scene = _Scene()..call(CallPhase.live);

    scene
      ..call(CallPhase.live, others: 1)
      ..call(
        CallPhase.live,
        others: 2,
        after: const Duration(milliseconds: 500),
      );

    expect(scene.chime.played, [
      AppSound.callJoined,
      AppSound.callJoined,
      AppSound.callJoined,
    ]);
  });

  test('with sound switched off, nothing plays', () {
    final scene = _Scene(sound: false)..call(CallPhase.live);

    scene
      ..call(CallPhase.live, others: 1)
      ..gone();

    expect(scene.chime.played, isEmpty);
  });
}
