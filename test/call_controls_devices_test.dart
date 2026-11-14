import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/call/call_controls.dart';
import 'package:loaf_native/ui/mock/mock_audio_devices.dart';
import 'package:loaf_native/ui/settings/voice_settings.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'voice_only_calls.dart';

import 'package:loaf_native/util/json_store.dart';

const _desktop = TargetPlatformVariant({TargetPlatform.linux});
const _mobile = TargetPlatformVariant({TargetPlatform.iOS});

/// A machine that says what it has when a test lets it.
class _Slow implements AudioDevices {
  final answer = Completer<void>();

  @override
  Future<List<AudioDevice>> microphones() async {
    await answer.future;
    return const [_rode];
  }

  @override
  Future<List<AudioDevice>> speakers() async => const [];

  @override
  Stream<void> get changes => const Stream.empty();
}

const _rode = AudioDevice('rode', 'RODE NT-USB');
const _sony = AudioDevice('sony', 'WH-1000XM3');
const _desk = AudioDevice('desk', 'Desk Speakers');

/// A call's controls on a machine with [microphones] and [speakers].
Future<VoiceController> _pump(
  WidgetTester tester, {
  List<AudioDevice> Function()? microphones,
  VoiceSettings saved = const VoiceSettings(),
  VoiceOnlyCalls? calls,
  AudioDevices? devices,
}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final voice = await VoiceController.load(
    MemoryStore<VoiceSettings>(saved),
    devices:
        devices ??
        MemoryAudioDevices(
          microphones: microphones ?? () => const [_rode, _sony],
          speakers: () => const [_desk],
        ),
  );
  addTearDown(voice.dispose);
  await tester.pumpWidget(
    VoiceScope(
      controller: voice,
      child: MaterialApp(
        theme: loafLightTheme(),
        home: Scaffold(
          body: CallControls(calls: calls ?? VoiceOnlyCalls(), onLeave: () {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return voice;
}

Future<void> _open(WidgetTester tester, String menu) async {
  await tester.tap(find.byTooltip(menu));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the microphone and deafen each have a device menu',
    variant: _desktop,
    (tester) async {
      await _pump(tester);

      expect(find.byTooltip('Microphone settings'), findsOneWidget);
      expect(find.byTooltip('Speaker settings'), findsOneWidget);
    },
  );

  testWidgets(
    'the microphone menu lists the system default and the '
    'microphones',
    variant: _desktop,
    (tester) async {
      await _pump(tester);

      await _open(tester, 'Microphone settings');

      expect(find.text('system default'), findsOneWidget);
      expect(find.text('RODE NT-USB'), findsOneWidget);
      expect(find.text('WH-1000XM3'), findsOneWidget);
      expect(find.text('Desk Speakers'), findsNothing);
    },
  );

  testWidgets('picking a microphone chooses it', variant: _desktop, (
    tester,
  ) async {
    final voice = await _pump(tester);
    await _open(tester, 'Microphone settings');

    await tester.tap(find.text('WH-1000XM3'));
    await tester.pumpAndSettle();

    expect(voice.microphone, _sony);
  });

  testWidgets('picking the system default goes back to it', variant: _desktop, (
    tester,
  ) async {
    final voice = await _pump(
      tester,
      saved: const VoiceSettings(microphone: _rode),
    );
    await _open(tester, 'Microphone settings');

    await tester.tap(find.text('system default'));
    await tester.pumpAndSettle();

    expect(voice.microphone, isNull);
  });

  testWidgets(
    'closing the menu without picking leaves the choice',
    variant: _desktop,
    (tester) async {
      final voice = await _pump(
        tester,
        saved: const VoiceSettings(microphone: _rode),
      );
      await _open(tester, 'Microphone settings');

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(voice.microphone, _rode);
    },
  );

  testWidgets(
    'the speaker menu lists the system default and the speakers',
    variant: _desktop,
    (tester) async {
      await _pump(tester);

      await _open(tester, 'Speaker settings');

      expect(find.text('system default'), findsOneWidget);
      expect(find.text('Desk Speakers'), findsOneWidget);
      expect(find.text('RODE NT-USB'), findsNothing);
    },
  );

  testWidgets('picking a speaker chooses it', variant: _desktop, (
    tester,
  ) async {
    final voice = await _pump(tester);
    await _open(tester, 'Speaker settings');

    await tester.tap(find.text('Desk Speakers'));
    await tester.pumpAndSettle();

    expect(voice.speaker, _desk);
  });

  testWidgets(
    'a microphone plugged in since the controls were drawn is in '
    'the menu',
    variant: _desktop,
    (tester) async {
      var microphones = const [_rode];
      await _pump(tester, microphones: () => microphones);

      microphones = const [_rode, _sony];
      await _open(tester, 'Microphone settings');

      expect(find.text('WH-1000XM3'), findsOneWidget);
    },
  );

  testWidgets(
    'a chosen microphone that is gone shows as not connected',
    variant: _desktop,
    (tester) async {
      await _pump(
        tester,
        microphones: () => const [_rode],
        saved: const VoiceSettings(microphone: _sony),
      );

      await _open(tester, 'Microphone settings');

      expect(find.text('WH-1000XM3 · not connected'), findsOneWidget);
    },
  );

  testWidgets(
    'the menu checks the microphone chosen, alone',
    variant: _desktop,
    (tester) async {
      await _pump(tester, saved: const VoiceSettings(microphone: _rode));

      await _open(tester, 'Microphone settings');

      final checks = find.byIcon(LucideIcons.check);
      expect(checks, findsOneWidget);
      expect(
        find.ancestor(
          of: checks,
          matching: find.ancestor(
            of: find.text('RODE NT-USB'),
            matching: find.byWidgetPredicate((w) => w is PopupMenuEntry),
          ),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('a phone draws no device menus', variant: _mobile, (
    tester,
  ) async {
    await _pump(tester);

    expect(find.byTooltip('Microphone settings'), findsNothing);
    expect(find.byTooltip('Speaker settings'), findsNothing);
  });

  testWidgets(
    'asking again before the machine has answered opens one '
    'menu',
    variant: _desktop,
    (tester) async {
      final machine = _Slow();
      await _pump(tester, devices: machine);

      await tester.tap(find.byTooltip('Microphone settings'));
      await tester.pump();
      await tester.tap(find.byTooltip('Microphone settings'));
      await tester.pump();
      machine.answer.complete();
      await tester.pumpAndSettle();

      expect(find.text('system default'), findsOneWidget);
    },
  );

  testWidgets('the menu opens again after it has closed', variant: _desktop, (
    tester,
  ) async {
    await _pump(tester);
    await _open(tester, 'Microphone settings');
    await tester.tap(find.text('RODE NT-USB'));
    await tester.pumpAndSettle();

    await _open(tester, 'Microphone settings');

    expect(find.text('system default'), findsOneWidget);
  });

  testWidgets(
    'a blocked microphone says it could not be opened',
    variant: _desktop,
    (tester) async {
      await _pump(tester, calls: VoiceOnlyCalls()..micBlocked = true);

      expect(find.byTooltip("Couldn't open your microphone"), findsOneWidget);
    },
  );

  testWidgets('a blocked microphone keeps its device menu', variant: _desktop, (
    tester,
  ) async {
    await _pump(tester, calls: VoiceOnlyCalls()..micBlocked = true);

    expect(find.byTooltip('Microphone settings'), findsOneWidget);
  });
}
