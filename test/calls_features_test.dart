import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/call/call_controls.dart';
import 'package:loaf_native/ui/call/calls.dart';
import 'package:loaf_native/ui/call/call_tile.dart';
import 'package:loaf_native/ui/call/call_view.dart';
import 'package:loaf_native/ui/call/voice_channel_page.dart';
import 'package:loaf_native/ui/mock/mock_audio_devices.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/settings/voice_settings.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/widgets/speaking_ring.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'voice_only_calls.dart';

const _desktop = TargetPlatformVariant({TargetPlatform.linux});
const _mobile = TargetPlatformVariant({TargetPlatform.iOS});

const _oven = Channel(id: '!oven', name: 'oven', kind: ChannelKind.voice);
const _ada = Member('@ada:loaf.test', 'ada', Color(0xFF884422));

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  VoiceController? voice,
}) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final Widget app = MaterialApp(
    theme: loafLightTheme(),
    home: Scaffold(body: child),
  );
  await tester.pumpWidget(
    voice == null ? app : VoiceScope(controller: voice, child: app),
  );
  await tester.pumpAndSettle();
}

VoiceController _voice({VoiceSettings saved = const VoiceSettings()}) {
  final voice = VoiceController(
    store: MemoryVoiceStore(),
    devices: MemoryAudioDevices(),
    settings: saved,
  );
  addTearDown(voice.dispose);
  return voice;
}

Widget _controls(Calls calls) => CallControls(calls: calls, onLeave: () {});

Widget _lobby(Calls calls) =>
    VoiceChannelPage(channel: _oven, calls: calls, onJoin: () {});

/// A button that opens [ada]'s tile actions the way a right click does;
/// with [you], as on your own tile.
Widget _tileActions(Calls calls, {bool you = false}) => Builder(
  builder: (context) => TextButton(
    onPressed: () =>
        showTileActions(context, calls, TileInfo(_ada, you: you), Offset.zero),
    child: const Text('open'),
  ),
);

void main() {
  group('calls with voice alone, on a computer', () {
    testWidgets('keep mute, deafen and leave', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, _controls(VoiceOnlyCalls()));

      expect(find.byIcon(LucideIcons.mic), findsOneWidget);
      expect(find.byIcon(LucideIcons.headphones), findsOneWidget);
      expect(find.byTooltip('Leave call'), findsOneWidget);
    });

    testWidgets('draw no camera button', variant: _desktop, (tester) async {
      await _pump(tester, _controls(VoiceOnlyCalls()));

      expect(find.byIcon(LucideIcons.videoOff), findsNothing);
    });

    testWidgets('draw no screen share button', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, _controls(VoiceOnlyCalls()));

      expect(find.byTooltip('Share screen'), findsNothing);
    });

    testWidgets('draw no device menus', variant: _desktop, (tester) async {
      await _pump(tester, _controls(VoiceOnlyCalls()));

      expect(find.byTooltip('Microphone settings'), findsNothing);
      expect(find.byTooltip('Speaker settings'), findsNothing);
      expect(find.byTooltip('Camera settings'), findsNothing);
    });

    testWidgets("offer no volume for someone's tile", variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, _tileActions(VoiceOnlyCalls()));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Pin'), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
    });
  });

  group('your own tile', () {
    CallSession live() => const CallSession(
      target: _oven,
      spaceName: 'Bakery',
      phase: CallPhase.live,
      participants: [],
    );

    test('is marked speaking while you speak', () {
      final calls = VoiceOnlyCalls()..speaking = true;

      expect(callTiles(calls, live()).first.speaking, isTrue);
    });

    test('is not while you do not', () {
      final calls = VoiceOnlyCalls();

      expect(callTiles(calls, live()).first.speaking, isFalse);
    });
  });

  group("a tile's ring", () {
    Future<bool> ringing(
      WidgetTester tester, {
      required bool speaking,
      bool dimmed = false,
    }) async {
      await _pump(
        tester,
        SizedBox(
          width: 300,
          height: 200,
          child: CallTile(
            info: TileInfo(_ada, speaking: speaking),
            dimmed: dimmed,
          ),
        ),
      );
      return tester.widget<SpeakingRing>(find.byType(SpeakingRing)).speaking;
    }

    testWidgets('is lit while they speak', (tester) async {
      expect(await ringing(tester, speaking: true), isTrue);
    });

    testWidgets('is out while they do not', (tester) async {
      expect(await ringing(tester, speaking: false), isFalse);
    });

    testWidgets('is out while the call is not connected, whatever was '
        'last heard', (tester) async {
      expect(await ringing(tester, speaking: true, dimmed: true), isFalse);
    });
  });

  group('with voice settings to keep it in', () {
    testWidgets("someone's tile offers their volume", variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, _tileActions(VoiceOnlyCalls()), voice: _voice());

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(Slider), findsOneWidget);
    });

    testWidgets('your own tile offers none', variant: _desktop, (tester) async {
      await _pump(
        tester,
        _tileActions(VoiceOnlyCalls(), you: true),
        voice: _voice(),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Pin'), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
    });

    testWidgets('the slider starts where they were set', variant: _desktop, (
      tester,
    ) async {
      await _pump(
        tester,
        _tileActions(VoiceOnlyCalls()),
        voice: _voice(saved: VoiceSettings(volumes: {_ada.id: 0.5})),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(tester.widget<Slider>(find.byType(Slider)).value, 0.5);
      expect(find.text('50%'), findsOneWidget);
    });

    testWidgets('dragging the slider sets their volume', variant: _desktop, (
      tester,
    ) async {
      final voice = _voice();
      await _pump(tester, _tileActions(VoiceOnlyCalls()), voice: voice);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(Slider), const Offset(-60, 0));
      await tester.pumpAndSettle();

      expect(voice.volumeOf(_ada.id), lessThan(1));
    });

    testWidgets(
      'the slider moves in steps of five in a hundred',
      variant: _desktop,
      (tester) async {
        final voice = _voice();
        await _pump(tester, _tileActions(VoiceOnlyCalls()), voice: voice);
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await tester.drag(find.byType(Slider), const Offset(-37, 0));
        await tester.pumpAndSettle();

        final twentieths = voice.volumeOf(_ada.id) * 20;
        expect(twentieths, closeTo(twentieths.round(), 1e-9));
      },
    );
  });

  group('calls with voice alone, on a phone', () {
    testWidgets('draw no audio output button', variant: _mobile, (
      tester,
    ) async {
      await _pump(tester, _controls(VoiceOnlyCalls()));

      expect(find.byTooltip('Audio output'), findsNothing);
    });

    testWidgets('draw no camera button', variant: _mobile, (tester) async {
      await _pump(tester, _controls(VoiceOnlyCalls()));

      expect(find.byIcon(LucideIcons.videoOff), findsNothing);
    });
  });

  testWidgets(
    "a voice channel whose join failed says so, and offers to retry",
    (tester) async {
      final calls = VoiceOnlyCalls()
        ..session = const CallSession(
          target: _oven,
          phase: CallPhase.failed,
          participants: [],
        );
      await _pump(tester, _lobby(calls));

      expect(find.text("couldn't connect"), findsOneWidget);
      expect(find.text('retry'), findsOneWidget);
      expect(find.text('join voice'), findsNothing);
    },
    variant: _desktop,
  );

  group('the lobby of calls with voice alone', () {
    testWidgets('offers to join', variant: _desktop, (tester) async {
      await _pump(tester, _lobby(VoiceOnlyCalls()));

      expect(find.text('join voice'), findsOneWidget);
    });

    testWidgets('draws no camera toggle', variant: _desktop, (tester) async {
      await _pump(tester, _lobby(VoiceOnlyCalls()));

      expect(find.byTooltip('Turn camera on'), findsNothing);
    });

    testWidgets('of a channel that cannot be joined says why, with no button', (
      tester,
    ) async {
      await _pump(tester, _lobby(VoiceOnlyCalls(canJoin: false)));

      expect(find.text('join voice'), findsNothing);
      expect(
        find.text("calls in encrypted rooms aren't supported yet"),
        findsOneWidget,
      );
    }, variant: _desktop);
  });
}
