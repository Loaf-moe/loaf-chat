import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/homeserver.dart';
import 'package:loaf_native/ui/auth/loaf_session.dart';
import 'package:loaf_native/ui/auth/sign_in_state.dart';
import 'package:loaf_native/ui/mock/mock_homeserver.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

/// A session that is not a MockSession, the way MatrixSession is not: its
/// notices are true, but the flows behind them are not built yet.
class _RealSession extends ChangeNotifier implements LoafSession {
  _RealSession(this.trust);

  @override
  final DeviceTrust trust;

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
  testWidgets('verifying a real session is not the mock flow', (tester) async {
    final session = _RealSession(DeviceTrust.unverified);
    addTearDown(session.dispose);
    await _pumpShell(tester, session);
    await _act(tester, 'verify this session', 'verify');
    expect(
      find.text('verifying this device arrives in the next build'),
      findsOneWidget,
    );
    expect(find.text('use another device'), findsNothing);
    expect(find.text('use your recovery key'), findsNothing);
    // The notice is true, so it stays.
    expect(find.byTooltip('verify this session'), findsOneWidget);
  });

  testWidgets('setting up recovery on a real session is not the mock flow', (
    tester,
  ) async {
    final session = _RealSession(DeviceTrust.noIdentity);
    addTearDown(session.dispose);
    await _pumpShell(tester, session);
    await _act(tester, 'set up recovery', 'set up');
    expect(
      find.text('setting up recovery arrives in the next build'),
      findsOneWidget,
    );
    expect(find.textContaining('recovery key'), findsNothing);
    expect(find.byTooltip('set up recovery'), findsOneWidget);
  });
}
