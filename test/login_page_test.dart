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
  // The server field is last in the column; in password mode the username
  // and password fields come before it.
  await tester.enterText(find.byType(TextField).last, server);
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
    // …and so would offering a link to one that goes nowhere.
    expect(find.text('use a username and password'), findsNothing);
  });

  testWidgets('a password-capable server offers the form behind a link', (
    tester,
  ) async {
    await _pump(tester);
    await _useServer(tester, 'matrix.org');

    expect(tester.takeException(), isNull);
    // SSO stays primary; the form is one tap away, not stacked underneath.
    expect(find.text('continue with single sign-on'), findsOneWidget);
    expect(find.text('username'), findsNothing);

    await tester.tap(find.text('use a username and password'));
    await tester.pumpAndSettle();

    expect(find.text('username'), findsOneWidget);
    expect(find.text('password'), findsOneWidget);
    expect(find.text('sign in'), findsOneWidget);

    // And it is reversible.
    await tester.tap(find.text('back to single sign-on'));
    await tester.pumpAndSettle();
    expect(find.text('continue with single sign-on'), findsOneWidget);
    expect(find.text('username'), findsNothing);
  });

  testWidgets('switching homeservers drops the password choice', (
    tester,
  ) async {
    await _pump(tester);
    await _useServer(tester, 'matrix.org');
    await tester.tap(find.text('use a username and password'));
    await tester.pumpAndSettle();
    expect(find.text('username'), findsOneWidget);

    // Back to a server with no password flow: the form must not persist.
    await tester.tap(find.text('matrix.org'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'loaf.moe');
    await tester.tap(find.text('connect'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(tester.takeException(), isNull);
    expect(find.text('username'), findsNothing);
    expect(find.text('continue with loaf.moe'), findsOneWidget);
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
