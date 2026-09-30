import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/widgets/loaf_avatar.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

BoxDecoration _decoration(WidgetTester tester) =>
    tester
            .widget<Container>(
              find.descendant(
                of: find.byType(LoafAvatar),
                matching: find.byType(Container),
              ),
            )
            .decoration!
        as BoxDecoration;

void main() {
  testWidgets('draws its label on its colour', (tester) async {
    await tester.pumpWidget(
      _host(
        LoafAvatar(
          label: 'AB',
          color: Colors.red,
          size: 36,
          textStyle: loafBody(13, 600),
        ),
      ),
    );
    expect(find.text('AB'), findsOneWidget);
    final decoration = _decoration(tester);
    expect(decoration.color, Colors.red);
    expect(decoration.shape, BoxShape.circle);
  });

  testWidgets('a radius makes a rounded square', (tester) async {
    await tester.pumpWidget(
      _host(
        LoafAvatar(
          label: 'AB',
          color: Colors.red,
          size: 36,
          radius: 10,
          textStyle: loafBody(13, 600),
        ),
      ),
    );
    final decoration = _decoration(tester);
    expect(decoration.borderRadius, BorderRadius.circular(10));
    expect(decoration.shape, BoxShape.rectangle);
  });

  testWidgets('is exactly its size', (tester) async {
    await tester.pumpWidget(
      _host(
        LoafAvatar(
          label: 'AB',
          color: Colors.red,
          size: 36,
          textStyle: loafBody(13, 600),
        ),
      ),
    );
    expect(tester.getSize(find.byType(LoafAvatar)), const Size(36, 36));
  });
}
