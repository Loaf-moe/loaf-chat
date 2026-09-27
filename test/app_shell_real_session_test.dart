import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/homeserver.dart';
import 'package:loaf_native/ui/auth/loaf_session.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:loaf_native/ui/mock/mock_homeserver.dart';
import 'package:loaf_native/ui/mock/mock_verifier.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/verifier.dart';

/// A session that is not a MockSession, the way MatrixSession is not: its
/// panels run on whatever [verifier] it hands out, and its trust changes
/// only when it says so.
class _RealSession extends ChangeNotifier implements LoafSession {
  _RealSession(this.trust, this.verifier);

  @override
  final DeviceTrust trust;
  @override
  final Verifier verifier;

  @override
  AccountState get account => AccountState.signedIn;
  @override
  SoftLogout? get softLogout => null;
  @override
  IncomingRequest? get incoming => null;
  @override
  String get homeserverName => 'loaf.test';
  @override
  Homeserver newHomeserver() => MockHomeserver();
  @override
  void signedIn() {}
  @override
  void signOut() {}
  @override
  void markVerified() {}
  @override
  void clearIncoming() {}
  @override
  bool consumeFailure() => false;
}

Future<void> _pumpShell(WidgetTester tester, LoafSession session) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: AppShell(session: session),
    ),
  );
  await tester.pumpAndSettle();
}

/// Tile, then the notice's own button, then whatever it opens.
Future<void> _act(WidgetTester tester, String tile, String action) async {
  await tester.tap(find.byTooltip(tile));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('verifying a real session opens its own panel', (tester) async {
    final session = _RealSession(DeviceTrust.unverified, MockVerifier());
    addTearDown(session.dispose);
    await _pumpShell(tester, session);
    await _act(tester, 'verify this session', 'verify');
    expect(find.text('use your recovery key'), findsOneWidget);
    // No other device of yours to ask: the route isn't offered.
    expect(find.text('use another device'), findsNothing);
  });

  testWidgets('a real session unlocked is trusted by its own word', (
    tester,
  ) async {
    final session = _RealSession(
      DeviceTrust.unverified,
      MockVerifier(otherSessions: const ['Element on Mac']),
    );
    addTearDown(session.dispose);
    await _pumpShell(tester, session);
    await _act(tester, 'verify this session', 'verify');
    expect(find.text('Element on Mac'), findsOneWidget);
    await tester.tap(find.text('use your recovery key'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(
      find.widgetWithText(TextField, 'recovery key or passphrase'),
      'bread before breakfast',
    );
    await tester.tap(find.text('unlock'));
    await tester.pump(MockVerifier.keyCheckDelay);
    expect(find.text('restoring history'), findsOneWidget);
    // Its trust is read from the SDK, so the notice waits for it.
    expect(find.byTooltip('verify this session'), findsOneWidget);
    await tester.pump(MockVerifier.restoreTick * 20);
    await tester.pumpAndSettle();
  });

  testWidgets('setting up recovery on a real session opens its own panel', (
    tester,
  ) async {
    final session = _RealSession(DeviceTrust.noIdentity, MockVerifier());
    addTearDown(session.dispose);
    await _pumpShell(tester, session);
    await _act(tester, 'set up recovery', 'set up');
    expect(find.text('create my recovery key'), findsOneWidget);
  });
}
