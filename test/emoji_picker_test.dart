import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/emoji/emoji_picker.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

final _mobile = TargetPlatformVariant.only(TargetPlatform.iOS);
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

Future<void> _pumpShell(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: const AppShell(),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _picker() => find.byType(EmojiPicker);
Finder _inPicker(Finder f) => find.descendant(of: _picker(), matching: f);

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(_inPicker(find.byType(TextField)), query);
  await tester.pumpAndSettle();
}

Future<void> _openFromComposer(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Emoji'));
  await tester.pumpAndSettle();
}

void main() {
  group('from the composer', () {
    testWidgets('a popover on a computer', variant: _desktop, (tester) async {
      await _pumpShell(tester, const Size(1440, 900));
      await _openFromComposer(tester);

      expect(_picker(), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('a sheet on a phone', variant: _mobile, (tester) async {
      await _pumpShell(tester, const Size(390, 844));
      await _openFromComposer(tester);

      expect(_picker(), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('picking inserts at the cursor', (tester) async {
      await _pumpShell(tester, const Size(1440, 900));
      final field = find.byType(TextField).last;
      await tester.enterText(field, 'fresh ');
      await _openFromComposer(tester);

      await _search(tester, 'baguette');
      await tester.tap(_inPicker(find.text('🥖')));
      await tester.pumpAndSettle();

      expect(_picker(), findsNothing);
      expect(tester.widget<TextField>(field).controller!.text, 'fresh 🥖');
    });
  });

  group('the picker', () {
    testWidgets('search finds by name', (tester) async {
      await _pumpShell(tester, const Size(1440, 900));
      await _openFromComposer(tester);

      await _search(tester, 'bread');

      expect(_inPicker(find.text('🍞')), findsOneWidget);
      expect(_inPicker(find.text('🥖')), findsOneWidget);
      expect(_inPicker(find.text('😀')), findsNothing);
    });

    testWidgets('a category tab shows that category', (tester) async {
      await _pumpShell(tester, const Size(1440, 900));
      await _openFromComposer(tester);
      expect(_inPicker(find.text('😀')), findsOneWidget);

      await tester.tap(_inPicker(find.byTooltip('Food & Drink')));
      await tester.pumpAndSettle();

      expect(_inPicker(find.text('🍞')), findsOneWidget);
      expect(_inPicker(find.text('😀')), findsNothing);
    });

    testWidgets('remembers what you picked', (tester) async {
      await _pumpShell(tester, const Size(1440, 900));
      await _openFromComposer(tester);
      await _search(tester, 'baguette');
      await tester.tap(_inPicker(find.text('🥖')));
      await tester.pumpAndSettle();

      await _openFromComposer(tester);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('emoji-recents')),
          matching: find.text('🥖'),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('from a message, a pick is a reaction', variant: _desktop, (
    tester,
  ) async {
    await _pumpShell(tester, const Size(1440, 900));

    await tester.tap(
      find.textContaining('first bake on the fixed oven'),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More reactions'));
    await tester.pumpAndSettle();
    await _search(tester, 'baguette');
    await tester.tap(_inPicker(find.text('🥖')));
    await tester.pumpAndSettle();

    // Ada's photo already had one 🥖; yours makes two.
    expect(find.text('🥖 2'), findsOneWidget);
    expect(find.byIcon(LucideIcons.smilePlus), findsWidgets);
  });
}
