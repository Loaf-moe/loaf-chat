import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/channel/composer.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

Future<void> _pump(WidgetTester tester, double textScale) async {
  tester.view.physicalSize = const Size(800, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Composer(channelName: 'general'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // iOS Text Size shrinks or grows everything; the typed line has to stay on
  // the buttons' centreline either way, not just at the default size.
  for (final scale in [0.82, 1.0, 1.3]) {
    testWidgets('a single line sits on the controls\' centreline at '
        'text scale $scale', (tester) async {
      await _pump(tester, scale);

      final field = tester.getCenter(find.byType(EditableText));
      final plus = tester.getCenter(find.byIcon(LucideIcons.plus));
      expect(field.dy, moreOrLessEquals(plus.dy, epsilon: 0.5));
    });
  }
}
