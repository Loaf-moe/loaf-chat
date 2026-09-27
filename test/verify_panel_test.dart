import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/mock/mock_verifier.dart';
import 'package:loaf_native/ui/mock/mock_session.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/verification_controller.dart';
import 'package:loaf_native/ui/verify/verify_panel.dart';
import 'package:loaf_native/ui/verify/verify_state.dart';
import 'package:loaf_native/ui/verify/verify_steps.dart';

const _wide = Size(1440, 900);
const _route = Duration(milliseconds: 400);

Future<MockSession> _pumpShell(
  WidgetTester tester, [
  MockSession? session,
]) async {
  tester.view.physicalSize = _wide;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final s = session ?? MockSession();
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

/// A session whose trust the SDK hasn't re-read yet: the notice stays, so a
/// flow put away can be opened again. [receiveRequest] can't flip it either.
class _TrustLagsSession extends MockSession {
  @override
  DeviceTrust get trust => DeviceTrust.unverified;
}

/// Waits out the frame that notices [MockSession.receiveRequest] and the one
/// that pushes its panel.
Future<void> _incomingShows(WidgetTester tester, Duration settle) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(settle);
  expect(find.text('is this you?'), findsOneWidget);
}

/// Up to the set-up panel's create button, on a fresh account.
Future<void> _toSetUp(WidgetTester tester, MockSession s) async {
  s.useFreshAccount();
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('set up recovery'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('set up'));
  await tester.pumpAndSettle();
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

  testWidgets('a second sign-in asking while one is open is dropped', (
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

  testWidgets("that's not me cancels and says what to do", (tester) async {
    final s = await _pumpShell(tester);
    s.receiveRequest();
    // Pushed after the frame that noticed the request.
    await tester.pump();
    await tester.pump();
    await tester.pump(_route);
    await tester.tap(find.text("that's not me"));
    await tester.pump(_route);
    expect(
      find.textContaining('sign that device out from another app'),
      findsOneWidget,
    );
    await tester.tap(find.text('close'));
    await tester.pumpAndSettle();
    expect(s.incoming, isNull);
  });

  testWidgets(
    'an unsaved new key cannot be escaped away, but a saved one can',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      final c = VerificationController.at(
        const VerifyState(step: VerifyStep.showKey),
        purpose: VerifyPurpose.setUp,
        verifier: MockVerifier(),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showVerifyPanel(context, c),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('copy'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('copy'), findsOneWidget, reason: 'the key is unsaved');

      await tester.tap(find.text('copy'));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('copy'), findsNothing);
    },
  );

  testWidgets(
    'a phone cannot swipe or tap away a key being made',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      final c = VerificationController.at(
        const VerifyState(step: VerifyStep.showKey),
        purpose: VerifyPurpose.setUp,
        verifier: MockVerifier(),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showVerifyPanel(context, c),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('copy'), findsOneWidget);

      // Dragging the sheet down hard would normally close it.
      await tester.fling(find.text('copy'), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(
        find.text('copy'),
        findsOneWidget,
        reason: 'the sheet cannot be dragged away while the key is unsaved',
      );

      // Tapping the barrier, above the sheet.
      await tester.tapAt(const Offset(200, 10));
      await tester.pumpAndSettle();
      expect(find.text('copy'), findsOneWidget);

      await tester.tap(find.text('copy'));
      await tester.pump();

      await tester.tapAt(const Offset(200, 10));
      await tester.pumpAndSettle();
      expect(find.text('copy'), findsNothing);
    },
  );

  testWidgets(
    'a key put away while being made waits in the rail, and is saved there',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      final s = await _pumpShell(tester);
      await _toSetUp(tester, s);
      await tester.tap(find.text('create my recovery key'));
      await tester.pump();
      expect(find.text('creating…'), findsOneWidget);

      // Put away by tapping outside it: making a key never traps the panel.
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(_route);
      expect(find.text('creating…'), findsNothing);
      expect(find.byTooltip('your new recovery key'), findsOneWidget);
      expect(find.byTooltip('set up recovery'), findsNothing);

      await tester.pump(MockVerifier.keyCheckDelay);
      await tester.tap(find.byTooltip('your new recovery key'));
      await tester.pumpAndSettle();
      expect(
        find.text("it's shown once. save it before anything else"),
        findsOneWidget,
      );
      await tester.tap(find.text('show'));
      await tester.pump();
      await tester.pump(_route);
      expect(find.text(mockNewRecoveryKey), findsOneWidget);

      // Unsaved, it can't be put away.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text(mockNewRecoveryKey), findsOneWidget);

      await tester.tap(find.text('copy'));
      await tester.pump();
      await tester.tap(find.text("i've saved it"));
      await tester.pump();
      await tester.pump(VerificationController.doneLinger);
      await tester.pumpAndSettle();
      expect(find.text(mockNewRecoveryKey), findsNothing);
      expect(find.byTooltip('your new recovery key'), findsNothing);
      expect(s.trust, DeviceTrust.verified);
    },
  );

  testWidgets('the panel title lines up with what it heads', (tester) async {
    await _pumpShell(tester);
    await _openVerify(tester);
    final title = tester.getRect(find.text('verify this session').last);
    final lead = tester.getRect(find.textContaining("prove it's you"));
    expect(title.left, lead.left);
  });

  group('an incoming request never touches the open flow', () {
    testWidgets('a new key shown unsaved is still there to save after', (
      tester,
    ) async {
      final s = await _pumpShell(tester);
      await _toSetUp(tester, s);
      await tester.tap(find.text('create my recovery key'));
      await tester.pump(MockVerifier.keyCheckDelay);
      await tester.pumpAndSettle();
      expect(find.text(mockNewRecoveryKey), findsOneWidget);

      s.receiveRequest();
      await _incomingShows(tester, _route);
      await tester.tap(find.text("that's not me"));
      await tester.pump(_route);
      await tester.tap(find.text('close'));
      await tester.pumpAndSettle();
      expect(find.text('is this you?'), findsNothing);

      expect(find.text(mockNewRecoveryKey), findsOneWidget);
      await tester.tap(find.text('copy'));
      await tester.pump();
      await tester.tap(find.text("i've saved it"));
      await tester.pump();
      await tester.pump(VerificationController.doneLinger);
      await tester.pumpAndSettle();
      expect(find.text(mockNewRecoveryKey), findsNothing);
      expect(find.text('recovery is set up'), findsOneWidget);
    });

    testWidgets(
      'a key being made still shows once the request is put away',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final s = await _pumpShell(tester);
        await _toSetUp(tester, s);
        await tester.tap(find.text('create my recovery key'));
        await tester.pump();
        expect(find.text('creating…'), findsOneWidget);

        // Well inside the key check, so the key is still being made.
        const step = Duration(milliseconds: 100);
        s.receiveRequest();
        await _incomingShows(tester, step);
        // Put away by tapping outside it.
        await tester.tapAt(const Offset(10, 10));
        await tester.pump();
        await tester.pump(step * 2);
        await tester.pump();
        expect(find.text('is this you?'), findsNothing);
        expect(find.text('creating…'), findsOneWidget);

        await tester.pump(MockVerifier.keyCheckDelay);
        await tester.pumpAndSettle();
        expect(find.text(mockNewRecoveryKey), findsOneWidget);
      },
    );

    testWidgets(
      'a restore finishing under a request closes its own panel',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final s = await _pumpShell(tester);
        await _openVerify(tester);
        await tester.tap(find.text('use your recovery key'));
        await tester.pump(_route);
        await tester.enterText(
          find.widgetWithText(TextField, 'recovery key or passphrase'),
          mockRecoveryKey,
        );
        await tester.tap(find.text('unlock'));
        await tester.pump(MockVerifier.keyCheckDelay);
        expect(find.text('restoring history'), findsOneWidget);

        // Left on screen: the request stacks its panel on top of it.
        s.receiveRequest();
        await _incomingShows(tester, _route);
        await tester.pump(MockVerifier.restoreTick * 21);
        await tester.pump(VerificationController.doneLinger);
        await tester.pumpAndSettle();

        expect(find.text('is this you?'), findsOneWidget);
        expect(s.incoming, isNotNull);
        expect(
          find.textContaining('${mockNewDevice()} is verified'),
          findsNothing,
        );
        expect(find.text('restoring history'), findsNothing);
        expect(find.byType(DoneStep), findsNothing);
      },
    );

    testWidgets(
      'history restoring unseen carries on through a request',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final s = await _pumpShell(tester, _TrustLagsSession());
        await _openVerify(tester);
        await tester.tap(find.text('use your recovery key'));
        await tester.pump(_route);
        await tester.enterText(
          find.widgetWithText(TextField, 'recovery key or passphrase'),
          mockRecoveryKey,
        );
        await tester.tap(find.text('unlock'));
        await tester.pump(MockVerifier.keyCheckDelay);
        expect(find.text('restoring history'), findsOneWidget);
        await tester.tapAt(const Offset(10, 10));
        await tester.pump();
        await tester.pump(_route);
        await tester.pump();
        expect(find.text('restoring history'), findsNothing);

        s.receiveRequest();
        await _incomingShows(tester, _route);
        await tester.tap(find.text("that's not me"));
        await tester.pump(_route);
        await tester.tap(find.text('close'));
        await tester.pump();
        await tester.pump(_route);
        await tester.pump();
        expect(find.text('is this you?'), findsNothing);

        await _openVerify(tester);
        final restoring = find.text('restoring history').evaluate().isNotEmpty;
        final done = find
            .text('this session is verified')
            .evaluate()
            .isNotEmpty;
        expect(restoring || done, isTrue, reason: 'not started over');
        expect(find.text('use your recovery key'), findsNothing);

        await tester.pump(MockVerifier.restoreTick * 21);
        await tester.pump(VerificationController.doneLinger);
        await tester.pumpAndSettle();
      },
    );
  });
}
