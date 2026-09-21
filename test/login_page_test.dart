import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/auth/login_page.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

/// Renders one look at phone size. These are layout checks, not behaviour
/// checks — the screen is a mockup, and what can break is how it lays out.
Future<void> _pump(WidgetTester tester, LoginLook look) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: LoginPage(onSignedIn: () {}, look: look),
    ),
  );
  // The probing look has an indefinite spinner, so it never settles.
  if (look == LoginLook.probing) {
    await tester.pump(const Duration(milliseconds: 100));
  } else {
    await tester.pumpAndSettle();
  }
}

void main() {
  for (final look in LoginLook.values) {
    testWidgets('${look.name} lays out without overflowing', (tester) async {
      await _pump(tester, look);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a long provider name ellipsises instead of overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: LoginPage(
          onSignedIn: () {},
          ssoProviderName: 'an identity provider with a very long name indeed',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
