import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/shell/loaf_banner.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

Future<void> _pump(WidgetTester tester, Widget banner, double width) async {
  tester.view.physicalSize = Size(width, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(body: Column(children: [banner])),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the verification banner cannot be dismissed', (tester) async {
    await _pump(tester, LoafBanner.verify(onAction: () {}), 800);

    expect(find.text('verify'), findsOneWidget);
    // Dismissing it silently costs you message history, so there is no X.
    expect(
      find.byIcon(LucideIcons.x),
      findsNothing,
      reason: 'an unverified session must not be dismissable',
    );
  });

  testWidgets('the update banner can be dismissed', (tester) async {
    await _pump(
      tester,
      LoafBanner.update(version: '0.3.0', onAction: () {}, onDismiss: () {}),
      800,
    );

    expect(find.byIcon(LucideIcons.x), findsOneWidget);
  });

  for (final width in [390.0, 800.0, 1440.0]) {
    testWidgets('banners lay out at ${width.toInt()}px', (tester) async {
      await _pump(
        tester,
        Column(
          children: [
            LoafBanner.verify(onAction: () {}),
            LoafBanner.update(
              version: '0.3.0',
              onAction: () {},
              onDismiss: () {},
            ),
          ],
        ),
        width,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('verify this session'), findsOneWidget);
      expect(find.text('loaf 0.3.0 is ready'), findsOneWidget);
    });
  }
}
