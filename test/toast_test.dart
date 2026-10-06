import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/widgets/toast.dart';

void main() {
  Future<void> toast(WidgetTester tester, String text) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showToast(context, text),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    // In, after which its time starts.
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a short note is quick', (tester) async {
    await toast(tester, 'link copied');
    await tester.pump(const Duration(milliseconds: 1400));
    expect(find.text('link copied'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('link copied'), findsNothing);
  });

  testWidgets('a sentence stays long enough to read', (tester) async {
    const text = "IMG_0612.MOV is 174.3 MB, over this server's 20 MB limit";
    await toast(tester, text);
    await tester.pump(const Duration(milliseconds: 3500));
    expect(find.text(text), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text(text), findsNothing);
  });
}
