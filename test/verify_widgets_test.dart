import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/accounts.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/emoji_compare.dart';
import 'package:loaf_native/ui/verify/recovery_key.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  double width = 390,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 844),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Padding(padding: const EdgeInsets.all(20), child: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('EmojiCompare', () {
    testWidgets('shows all seven with their names, four over three', (
      tester,
    ) async {
      await _pump(tester, const EmojiCompare(emoji: mockSasEmoji));
      for (final e in mockSasEmoji) {
        expect(find.text(e.name), findsOneWidget);
      }
      final dog = tester.getRect(find.text('dog'));
      final pizza = tester.getRect(find.text('pizza'));
      final cactus = tester.getRect(find.text('cactus'));
      expect(dog.top, pizza.top);
      expect(cactus.top, greaterThan(dog.bottom));
    });

    testWidgets('holds at large text in a narrow panel', (tester) async {
      await _pump(
        tester,
        const EmojiCompare(emoji: mockSasEmoji),
        width: 340,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  test('groupKey regroups any spacing into fours', () {
    expect(groupKey('EsTc5rr9 Tj3W\n8ZkN'), 'EsTc 5rr9 Tj3W 8ZkN');
    expect(groupKey(mockRecoveryKey), mockRecoveryKey);
  });

  testWidgets(
    'a computer can select the key',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      await _pump(
        tester,
        const RecoveryKeyDisplay(recoveryKey: mockNewRecoveryKey),
      );
      expect(find.byType(SelectableText), findsOneWidget);
    },
  );

  testWidgets(
    'a phone shows the key as plain text',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      await _pump(
        tester,
        const RecoveryKeyDisplay(recoveryKey: mockNewRecoveryKey),
      );
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text(mockNewRecoveryKey), findsOneWidget);
    },
  );

  group('RecoveryKeyField', () {
    testWidgets('is hidden until revealed, and submits', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var submitted = false;
      await _pump(
        tester,
        RecoveryKeyField(
          controller: controller,
          onSubmit: () => submitted = true,
        ),
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isTrue,
      );

      await tester.tap(find.byTooltip('show'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isFalse,
      );

      await tester.enterText(find.byType(TextField), 'x');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(submitted, isTrue);
    });

    testWidgets(
      'only a phone gets a paste button',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await _pump(
          tester,
          RecoveryKeyField(controller: controller, onSubmit: () {}),
        );
        expect(find.byTooltip('paste'), findsOneWidget);
      },
    );

    testWidgets(
      'a computer pastes the usual way',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        await _pump(
          tester,
          RecoveryKeyField(controller: controller, onSubmit: () {}),
        );
        expect(find.byTooltip('paste'), findsNothing);
      },
    );
  });
}
