import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/settings/settings_page.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

Future<void> _open(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showSettings(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens on the account, over the app', (tester) async {
    await _open(tester, const Size(1440, 900));

    expect(tester.takeException(), isNull);
    // Settings is a detour: the screen behind it is still mounted.
    expect(find.text('open'), findsOneWidget);
    expect(find.text('display name'.toUpperCase()), findsOneWidget);
  });

  testWidgets('wide shows nav beside detail', (tester) async {
    await _open(tester, const Size(1440, 900));

    // Both panes at once: the nav entry and the profile content.
    expect(find.text('devices'), findsOneWidget);
    expect(find.text('account'), findsWidgets);
  });

  testWidgets('narrow shows the nav, then the detail in place', (tester) async {
    await _open(tester, const Size(390, 844));

    expect(tester.takeException(), isNull);
    // Nav only — no detail beside it.
    expect(find.text('display name'.toUpperCase()), findsNothing);

    await tester.tap(find.text('appearance'));
    await tester.pumpAndSettle();

    // The detail replaced the nav inside the same card.
    expect(find.text('devices'), findsNothing);
    expect(find.textContaining('not designed yet'), findsOneWidget);
  });

  testWidgets('closing returns to the app', (tester) async {
    await _open(tester, const Size(1440, 900));

    await tester.tap(find.byType(IconButton).first);
    await tester.pumpAndSettle();

    expect(find.text('devices'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
