import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_audio_devices.dart';
import 'package:loaf_native/ui/settings/settings_controls.dart';
import 'package:loaf_native/ui/settings/voice_section.dart';
import 'package:loaf_native/ui/settings/voice_settings.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _rode = AudioDevice('rode', 'RODE NT-USB');
const _sony = AudioDevice('sony', 'WH-1000XM3');
const _desk = AudioDevice('desk', 'Desk Speakers');

/// The section over a machine with [microphones] and [speakers].
Future<VoiceController> _pump(
  WidgetTester tester, {
  List<AudioDevice> Function()? microphones,
  List<AudioDevice> Function()? speakers,
  VoiceSettings saved = const VoiceSettings(),
  Stream<void> changes = const Stream.empty(),
}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final controller = await VoiceController.load(
    MemoryVoiceStore(saved),
    devices: MemoryAudioDevices(
      microphones: microphones ?? () => const [_rode, _sony],
      speakers: speakers ?? () => const [_desk],
      changes: changes,
    ),
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(body: VoiceSection(controller: controller)),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

/// The titles of the choices that are checked, top to bottom.
List<String> _checked(WidgetTester tester) => [
  for (final choice in tester.widgetList<SettingsChoice>(
    find.byType(SettingsChoice),
  ))
    if (choice.selected) choice.title,
];

List<String> _titles(WidgetTester tester) => [
  for (final choice in tester.widgetList<SettingsChoice>(
    find.byType(SettingsChoice),
  ))
    choice.title,
];

/// Each processing switch by its title, and whether it is on.
Map<String, bool> _switches(WidgetTester tester) => {
  for (final check in tester.widgetList<SettingsCheck>(
    find.byType(SettingsCheck),
  ))
    check.title: check.value,
};

void main() {
  testWidgets('lists the four kinds of processing as they start out', (
    tester,
  ) async {
    await _pump(tester);

    expect(_switches(tester), {
      'echo cancellation': true,
      'noise suppression': true,
      'automatic gain': true,
      'high-pass filter': false,
    });
  });

  testWidgets('a kind of processing switched off shows as off', (tester) async {
    await _pump(tester, saved: const VoiceSettings(automaticGain: false));

    expect(_switches(tester), {
      'echo cancellation': true,
      'noise suppression': true,
      'automatic gain': false,
      'high-pass filter': false,
    });
  });

  for (final (title, read) in <(String, bool Function(VoiceSettings))>[
    ('echo cancellation', (s) => s.echoCancellation),
    ('noise suppression', (s) => s.noiseSuppression),
    ('automatic gain', (s) => s.automaticGain),
    ('high-pass filter', (s) => !s.highPassFilter),
  ]) {
    testWidgets('tapping $title switches it over', (tester) async {
      final controller = await _pump(tester);

      await tester.tap(find.text(title));
      await tester.pump();

      expect(read(controller.settings.value), isFalse);
    });
  }

  testWidgets('lists the system default and every device, for each', (
    tester,
  ) async {
    await _pump(tester);

    expect(_titles(tester), [
      'system default',
      'RODE NT-USB',
      'WH-1000XM3',
      'system default',
      'Desk Speakers',
    ]);
  });

  testWidgets('with nothing chosen, the system default is checked for both', (
    tester,
  ) async {
    await _pump(tester);

    expect(_checked(tester), ['system default', 'system default']);
  });

  testWidgets('a chosen device is the one checked', (tester) async {
    await _pump(tester, saved: const VoiceSettings(microphone: _sony));

    expect(_checked(tester), ['WH-1000XM3', 'system default']);
  });

  testWidgets('tapping a microphone chooses it', (tester) async {
    final controller = await _pump(tester);

    await tester.tap(find.text('RODE NT-USB'));
    await tester.pump();

    expect(controller.microphone, _rode);
    expect(_checked(tester), ['RODE NT-USB', 'system default']);
  });

  testWidgets('tapping a speaker chooses it', (tester) async {
    final controller = await _pump(tester);

    await tester.tap(find.text('Desk Speakers'));
    await tester.pump();

    expect(controller.speaker, _desk);
  });

  testWidgets('tapping the system default goes back to it', (tester) async {
    final controller = await _pump(
      tester,
      saved: const VoiceSettings(microphone: _rode),
    );

    await tester.tap(find.text('system default').first);
    await tester.pump();

    expect(controller.microphone, isNull);
  });

  testWidgets('a chosen device that is gone is listed as not connected, '
      'still checked', (tester) async {
    await _pump(
      tester,
      microphones: () => const [_rode],
      saved: const VoiceSettings(microphone: _sony),
    );

    expect(_checked(tester), ['WH-1000XM3 · not connected', 'system default']);
  });

  testWidgets('a device plugged in while the section is open appears', (
    tester,
  ) async {
    final plugged = StreamController<void>();
    addTearDown(plugged.close);
    var microphones = const [_rode];
    await _pump(
      tester,
      microphones: () => microphones,
      changes: plugged.stream,
    );

    microphones = const [_rode, _sony];
    plugged.add(null);
    await tester.pumpAndSettle();

    expect(find.text('WH-1000XM3'), findsOneWidget);
  });
}
