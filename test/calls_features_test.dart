import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/call/call_controller.dart';
import 'package:loaf_native/ui/call/call_controls.dart';
import 'package:loaf_native/ui/call/call_tile.dart';
import 'package:loaf_native/ui/call/call_view.dart';
import 'package:loaf_native/ui/call/voice_channel_page.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'voice_only_calls.dart';

const _desktop = TargetPlatformVariant({TargetPlatform.linux});
const _mobile = TargetPlatformVariant({TargetPlatform.iOS});

const _oven = Channel(id: '!oven', name: 'oven', kind: ChannelKind.voice);
const _ada = Member('@ada:loaf.test', 'ada', Color(0xFF884422));

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

Widget _controls(Calls calls) => CallControls(calls: calls, onLeave: () {});

Widget _lobby(Calls calls) =>
    VoiceChannelPage(channel: _oven, calls: calls, onJoin: () {});

/// A button that opens [ada]'s tile actions the way a right click does.
Widget _tileActions(Calls calls) => Builder(
  builder: (context) => TextButton(
    onPressed: () =>
        showTileActions(context, calls, const TileInfo(_ada), Offset.zero),
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

      expect(find.byTooltip('Microphone'), findsNothing);
      expect(find.byTooltip('Camera'), findsNothing);
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

  testWidgets(
    'calls with every feature offer volume for a tile',
    variant: _desktop,
    (tester) async {
      final calls = CallController(me: _ada);
      addTearDown(calls.dispose);
      await _pump(tester, _tileActions(calls));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(Slider), findsOneWidget);
    },
  );

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
