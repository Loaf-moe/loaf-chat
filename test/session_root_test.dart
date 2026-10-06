import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/session_root.dart';
import 'package:loaf_native/ui/auth/sign_in_controller.dart';
import 'package:loaf_native/ui/mock/mock_session.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/mock/mock_verifier.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _wide = Size(1440, 900);

/// Tests that end on the sign-in screen pump past its probe first, so no
/// timer is left pending.
Future<MockSession> _pumpRoot(
  WidgetTester tester, {
  MockSession? session,
  Size size = _wide,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final s = session ?? MockSession();
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: SessionRoot(session: s),
    ),
  );
  await tester.pumpAndSettle();
  return s;
}

void main() {
  testWidgets('a signed-in session opens on the app', (tester) async {
    await _pumpRoot(tester);
    expect(find.text('The Starter Pack'), findsOneWidget);
  });

  testWidgets('signing out swaps in sign-in, and signing in swaps back', (
    tester,
  ) async {
    final s = await _pumpRoot(tester);
    s.signOut();
    await tester.pump();
    expect(find.text('looking for loaf.moe'), findsOneWidget);

    await tester.pump(SignInController.probeDelay);
    await tester.tap(find.text('continue with loaf.moe'));
    await tester.pump(SignInController.ssoSheetDelay);
    await tester.pumpAndSettle();
    expect(find.text('The Starter Pack'), findsOneWidget);
    expect(find.byTooltip('verify this session'), findsOneWidget);
  });

  testWidgets('an expired session asks for this account again', (tester) async {
    final s = await _pumpRoot(tester);
    s.expireSession();
    await tester.pump();
    await tester.pump(SignInController.probeDelay);
    expect(find.text('sign in again as @faore:loaf.moe'), findsOneWidget);

    await tester.tap(find.text('sign out instead'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('sign out'));
    await tester.pump();
    await tester.pump(SignInController.probeDelay);
    // A fresh sign-in: the server can be changed again.
    expect(find.text('sign in again as @faore:loaf.moe'), findsNothing);
    expect(find.text('on '), findsOneWidget);
  });

  testWidgets('a verified device shows no verify notice', (tester) async {
    await _pumpRoot(tester, session: MockSession(trust: DeviceTrust.verified));
    expect(find.byTooltip('verify this session'), findsNothing);
  });

  testWidgets('the debug menu can sign you out', (tester) async {
    await _pumpRoot(tester);
    await tester.tap(find.byTooltip('Debug'));
    await tester.pumpAndSettle();
    // The debug sheet scrolls; the session levers sit below the fold.
    await tester.ensureVisible(find.text('sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('sign out'));
    await tester.pump();
    await tester.pump(SignInController.probeDelay);
    expect(find.text('continue with loaf.moe'), findsOneWidget);
  });

  testWidgets('signing out with the panel open takes the panel too', (
    tester,
  ) async {
    final s = await _pumpRoot(tester);
    await tester.tap(find.byTooltip('verify this session'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('verify'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('use your recovery key'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(
      find.widgetWithText(TextField, 'recovery key or passphrase'),
      mockRecoveryKey,
    );
    await tester.tap(find.text('unlock'));
    await tester.pump(MockVerifier.keyCheckDelay);

    s.signOut();
    await tester.pump();
    await tester.pump(SignInController.probeDelay);
    expect(tester.takeException(), isNull);
    expect(find.text('restoring history'), findsNothing);
    expect(find.text('continue with loaf.moe'), findsOneWidget);
  });

  testWidgets('the debug menu can send a new sign-in to verify', (
    tester,
  ) async {
    await _pumpRoot(tester);
    await tester.tap(find.byTooltip('Debug'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('a new sign-in asks to verify'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('a new sign-in asks to verify'));
    await tester.pumpAndSettle();
    expect(find.text('is this you?'), findsOneWidget);
  });
}
