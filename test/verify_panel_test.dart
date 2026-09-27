import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/mock/mock_verifier.dart';
import 'package:loaf_native/ui/mock/mock_session.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/verification_controller.dart';

const _wide = Size(1440, 900);
const _route = Duration(milliseconds: 400);

Future<MockSession> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = _wide;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final s = MockSession();
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: AppShell(session: s),
    ),
  );
  await tester.pumpAndSettle();
  return s;
}

/// Tile, then the notice's own verify button, then the panel.
Future<void> _openVerify(WidgetTester tester) async {
  await tester.tap(find.byTooltip('verify this session'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('verify'));
  // The panel is pushed once the notice has closed, a frame later.
  await tester.pump();
  await tester.pump(_route);
}

void main() {
  testWidgets('the notice opens the panel on its choice', (tester) async {
    await _pumpShell(tester);
    await _openVerify(tester);
    expect(find.text('use another device'), findsOneWidget);
    expect(find.text('use your recovery key'), findsOneWidget);
  });

  testWidgets(
    'a recovery key verifies, restores, closes, and the notice goes',
    (tester) async {
      final s = await _pumpShell(tester);
      await _openVerify(tester);
      await tester.tap(find.text('use your recovery key'));
      await tester.pump(_route);
      expect(find.byTooltip('back'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'recovery key or passphrase'),
        mockRecoveryKey,
      );
      await tester.tap(find.text('unlock'));
      await tester.pump(MockVerifier.keyCheckDelay);
      expect(s.trust, DeviceTrust.verified);
      expect(find.byTooltip('verify this session'), findsNothing);
      expect(find.text('restoring history'), findsOneWidget);

      await tester.pump(MockVerifier.restoreTick * 21);
      expect(find.text('this session is verified'), findsWidgets);
      await tester.pump(VerificationController.doneLinger);
      await tester.pumpAndSettle();
      expect(find.text('restoring history'), findsNothing);
    },
  );

  testWidgets('emoji: match on both screens, then done', (tester) async {
    final s = await _pumpShell(tester);
    await _openVerify(tester);
    await tester.tap(find.text('use another device'));
    await tester.pump(MockVerifier.acceptDelay);
    expect(find.text('dog'), findsOneWidget);
    await tester.tap(find.text('they match'));
    await tester.pump(MockVerifier.confirmDelay);
    expect(s.trust, DeviceTrust.verified);
    await tester.pump(VerificationController.doneLinger);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Escape puts the panel away on a computer',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      await _pumpShell(tester);
      await _openVerify(tester);
      expect(find.text('use your recovery key'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('use your recovery key'), findsNothing);
    },
  );

  testWidgets(
    'putting it away mid-wait trusts nothing and leaves the notice',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      final s = await _pumpShell(tester);
      await _openVerify(tester);
      await tester.tap(find.text('use another device'));
      await tester.pump(_route);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(_route);
      await tester.pump(MockVerifier.acceptDelay);
      expect(tester.takeException(), isNull);
      expect(s.trust, DeviceTrust.unverified);
      expect(find.byTooltip('verify this session'), findsOneWidget);

      // Opening again starts over rather than resuming a stale wait.
      await _openVerify(tester);
      expect(find.text('use another device'), findsOneWidget);
    },
  );

  testWidgets(
    'a fresh account sets up recovery, and only after keeping the key',
    (tester) async {
      final s = await _pumpShell(tester);
      s.useFreshAccount();
      await tester.pumpAndSettle();
      expect(find.byTooltip('verify this session'), findsNothing);

      await tester.tap(find.byTooltip('set up recovery'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('set up'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('create my recovery key'));
      await tester.pump(MockVerifier.keyCheckDelay);
      await tester.pumpAndSettle();
      expect(find.text(mockNewRecoveryKey), findsOneWidget);

      await tester.tap(find.text("i've saved it"));
      await tester.pump();
      expect(
        s.trust,
        DeviceTrust.noIdentity,
        reason: 'not before the key is kept',
      );

      await tester.tap(find.text('copy'));
      await tester.pump();
      await tester.tap(find.text("i've saved it"));
      await tester.pump();
      expect(s.trust, DeviceTrust.verified);
      await tester.pump(VerificationController.doneLinger);
      await tester.pumpAndSettle();
      expect(find.byTooltip('set up recovery'), findsNothing);
    },
  );

  testWidgets('a second sign-in asking while one is open waits its turn', (
    tester,
  ) async {
    final s = await _pumpShell(tester);
    s.receiveRequest();
    await tester.pump();
    await tester.pump();
    await tester.pump(_route);
    final first = s.incoming;
    s.receiveRequest();
    await tester.pump();
    await tester.pump();
    await tester.pump(_route);
    expect(s.incoming, same(first));
    expect(find.text('is this you?'), findsOneWidget);
    await tester.tap(find.text('yes, verify it'));
    await tester.pump(_route);
    expect(tester.takeException(), isNull);
    expect(find.text('dog'), findsOneWidget);
    await tester.tap(find.text('they match'));
    await tester.pump(MockVerifier.confirmDelay);
    await tester.pump(VerificationController.doneLinger);
    await tester.pumpAndSettle();
  });

  testWidgets('a new sign-in pops up at once and uses the same emoji', (
    tester,
  ) async {
    final s = await _pumpShell(tester);
    s.receiveRequest();
    // Pushed after the frame that noticed the request.
    await tester.pump();
    await tester.pump();
    await tester.pump(_route);
    expect(find.text('is this you?'), findsOneWidget);
    expect(find.textContaining('signed in just now'), findsOneWidget);

    await tester.tap(find.text('yes, verify it'));
    await tester.pump(_route);
    expect(find.text('dog'), findsOneWidget);
    await tester.tap(find.text('they match'));
    await tester.pump(MockVerifier.confirmDelay);
    await tester.pump(VerificationController.doneLinger);
    await tester.pumpAndSettle();
    expect(s.incoming, isNull);
    expect(
      find.textContaining('is verified'),
      findsOneWidget,
      reason: 'the toast',
    );
  });

  testWidgets("that's not me cancels and points at settings", (tester) async {
    final s = await _pumpShell(tester);
    s.receiveRequest();
    // Pushed after the frame that noticed the request.
    await tester.pump();
    await tester.pump();
    await tester.pump(_route);
    await tester.tap(find.text("that's not me"));
    await tester.pump(_route);
    expect(
      find.textContaining('sign that device out in settings'),
      findsOneWidget,
    );
    await tester.tap(find.text('close'));
    await tester.pumpAndSettle();
    expect(s.incoming, isNull);
  });

  testWidgets('the panel title lines up with what it heads', (tester) async {
    await _pumpShell(tester);
    await _openVerify(tester);
    final title = tester.getRect(find.text('verify this session').last);
    final lead = tester.getRect(find.textContaining("prove it's you"));
    expect(title.left, lead.left);
  });
}
