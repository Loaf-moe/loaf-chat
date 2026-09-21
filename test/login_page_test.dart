import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/login_page.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: LoginPage(onSignedIn: () {}),
    ),
  );
  // Discovery is async; let it resolve.
  await tester.pumpAndSettle(const Duration(seconds: 2));
}

/// Replaces the homeserver and reconnects.
Future<void> _useServer(WidgetTester tester, String server) async {
  await tester.tap(find.text('loaf.moe'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, server);
  await tester.tap(find.text('connect'));
  await tester.pumpAndSettle(const Duration(seconds: 2));
}

void main() {
  testWidgets('loaf.moe offers SSO only — no password form', (tester) async {
    await _pump(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('continue with loaf.moe'), findsOneWidget);
    // loaf.moe delegates auth to Kanidm and advertises no password flow, so
    // showing a password box would be a lie.
    expect(find.text('password'), findsNothing);
    expect(find.text('username'), findsNothing);
  });

  testWidgets('a password-capable server gets a password form', (tester) async {
    await _pump(tester);
    await _useServer(tester, 'matrix.org');

    expect(tester.takeException(), isNull);
    expect(find.text('username'), findsOneWidget);
    expect(find.text('password'), findsOneWidget);
    expect(find.text('sign in'), findsOneWidget);
  });

  testWidgets('an unreachable server explains itself and offers a retry', (
    tester,
  ) async {
    await _pump(tester);
    await _useServer(tester, 'nope.example');

    expect(tester.takeException(), isNull);
    expect(
      find.textContaining("couldn't reach a matrix server"),
      findsOneWidget,
    );
    expect(find.text('try again'), findsOneWidget);
    expect(find.text('username'), findsNothing);
  });

  testWidgets('signing in hands control back to the caller', (tester) async {
    var signedIn = false;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: LoginPage(onSignedIn: () => signedIn = true),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await tester.tap(find.text('continue with loaf.moe'));
    await tester.pumpAndSettle();

    expect(signedIn, isTrue);
  });
}
