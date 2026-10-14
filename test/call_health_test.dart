import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/call/call_health.dart';
import 'package:loaf_native/ui/call/calls.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'voice_only_calls.dart';

const _desktop = TargetPlatformVariant({TargetPlatform.linux});
const _oven = Channel(id: '!oven', name: 'oven', kind: ChannelKind.voice);

/// The mark for a call in [phase] whose link is rated [quality]; no call
/// when [phase] is null.
Future<void> _pump(
  WidgetTester tester, {
  CallPhase? phase = CallPhase.live,
  CallQuality quality = CallQuality.good,
  bool quiet = false,
}) async {
  final calls = VoiceOnlyCalls()..quality = quality;
  addTearDown(calls.dispose);
  if (phase != null) {
    calls.session = CallSession(
      target: _oven,
      phase: phase,
      participants: const [],
    );
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      home: Scaffold(
        body: CallHealthMark(calls: calls, quiet: quiet),
      ),
    ),
  );
}

/// The one icon the mark draws, and the palette it draws from.
(Icon, LoafTokens) _drawn(WidgetTester tester) {
  final mark = find.byType(CallHealthMark);
  return (
    tester.widget<Icon>(find.descendant(of: mark, matching: find.byType(Icon))),
    LoafTokens.of(tester.element(mark)),
  );
}

void main() {
  testWidgets('a good link draws full bars in green', variant: _desktop, (
    tester,
  ) async {
    await _pump(tester);

    final (icon, tokens) = _drawn(tester);
    expect(icon.icon, LucideIcons.signal);
    expect(icon.color, tokens.online);
  });

  testWidgets('a good link, asked to be quiet, is muted', variant: _desktop, (
    tester,
  ) async {
    await _pump(tester, quiet: true);

    final (icon, tokens) = _drawn(tester);
    expect(icon.icon, LucideIcons.signal);
    expect(icon.color, tokens.textMuted);
  });

  testWidgets('a link not rated yet draws as a good one', variant: _desktop, (
    tester,
  ) async {
    await _pump(tester, quality: CallQuality.unknown);

    final (icon, tokens) = _drawn(tester);
    expect(icon.icon, LucideIcons.signal);
    expect(icon.color, tokens.online);
  });

  testWidgets('a weak link draws low bars in amber, quiet or not', (
    tester,
  ) async {
    await _pump(tester, quality: CallQuality.poor, quiet: true);

    final (icon, tokens) = _drawn(tester);
    expect(icon.icon, LucideIcons.signalLow);
    expect(icon.color, tokens.idle);
  }, variant: _desktop);

  testWidgets('a link barely there draws no bars in red', variant: _desktop, (
    tester,
  ) async {
    await _pump(tester, quality: CallQuality.bad, quiet: true);

    final (icon, tokens) = _drawn(tester);
    expect(icon.icon, LucideIcons.signalZero);
    expect(icon.color, tokens.accent);
  });

  testWidgets('reconnecting draws no bars in amber, whatever the rating', (
    tester,
  ) async {
    await _pump(tester, phase: CallPhase.reconnecting);

    final (icon, tokens) = _drawn(tester);
    expect(icon.icon, LucideIcons.signalZero);
    expect(icon.color, tokens.idle);
  }, variant: _desktop);

  for (final phase in [CallPhase.connecting, CallPhase.failed, null]) {
    testWidgets(
      '${phase?.name ?? 'no call'} draws nothing',
      variant: _desktop,
      (tester) async {
        await _pump(tester, phase: phase);

        expect(
          find.descendant(
            of: find.byType(CallHealthMark),
            matching: find.byType(Icon),
          ),
          findsNothing,
        );
      },
    );
  }

  group('the mark says what it means:', () {
    const says = {
      (CallPhase.live, CallQuality.good): 'connection is good',
      (CallPhase.live, CallQuality.unknown): 'connection is good',
      (CallPhase.live, CallQuality.poor): 'connection is weak',
      (CallPhase.live, CallQuality.bad): 'connection is very weak',
      (CallPhase.reconnecting, CallQuality.good): 'reconnecting…',
    };
    for (final MapEntry(key: (phase, quality), value: words) in says.entries) {
      testWidgets('${phase.name}, ${quality.name}', variant: _desktop, (
        tester,
      ) async {
        await _pump(tester, phase: phase, quality: quality);

        expect(find.byTooltip(words), findsOneWidget);
      });
    }
  });

  testWidgets('the mark names itself to a screen reader', variant: _desktop, (
    tester,
  ) async {
    await _pump(tester, quality: CallQuality.poor);

    expect(_drawn(tester).$1.semanticLabel, 'connection is weak');
  });

  testWidgets('on a phone, tapping the mark says what it means', (
    tester,
  ) async {
    await _pump(tester, quality: CallQuality.poor);

    await tester.tap(find.byType(CallHealthMark));
    await tester.pump();

    expect(find.text('connection is weak'), findsOneWidget);
    // The toast takes itself away.
    await tester.pump(const Duration(seconds: 5));
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
}
