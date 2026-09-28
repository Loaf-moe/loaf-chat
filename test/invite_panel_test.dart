import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/members/invite_panel.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/rooms/rooms.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/widgets/loaf_button.dart';

const _mika = Member('@mika:loaf.test', 'Mika Rye', Color(0xFF4E9E76));

Future<List<String>?> _pump(
  WidgetTester tester, {
  List<Member> people = const [_mika],
  required Future<void> Function(List<String> ids) onInvite,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showInvitePanel(
                context,
                roomName: 'bakery',
                people: people,
                onInvite: onInvite,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return null;
}

bool _enabled(WidgetTester tester) =>
    tester.widget<LoafButton>(find.byType(LoafButton)).onTap != null;

void main() {
  testWidgets('invite is dim until someone is chosen', (tester) async {
    await _pump(tester, onInvite: (_) async {});
    expect(_enabled(tester), isFalse);
    await tester.tap(find.text('Mika Rye'));
    await tester.pump();
    expect(_enabled(tester), isTrue);
  });

  testWidgets("a malformed id can't be invited", (tester) async {
    await _pump(tester, onInvite: (_) async {});
    final field = find.byType(TextField).last;
    for (final bad in ['bob', '@bob', 'bob:loaf.moe']) {
      await tester.enterText(field, bad);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.byType(InputChip), findsNothing);
    }
    expect(_enabled(tester), isFalse);
  });

  testWidgets('inviting shows inviting and no cancel', (tester) async {
    final gate = Completer<void>();
    await _pump(tester, onInvite: (_) => gate.future);
    await tester.tap(find.text('Mika Rye'));
    await tester.pump();
    await tester.tap(find.text('invite'));
    await tester.pump();

    expect(find.text('inviting…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('cancel'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
    "a partly refused invite marks who didn't go and retries only them",
    (tester) async {
      final sent = <List<String>>[];
      await _pump(
        tester,
        people: const [
          _mika,
          Member('@jun:loaf.test', 'Jun', Color(0xFF7C3AED)),
        ],
        onInvite: (ids) async {
          sent.add(ids);
          if (sent.length == 1) {
            throw const InviteRefused({'@jun:loaf.test': 'forbidden'});
          }
        },
      );
      await tester.tap(find.text('Mika Rye'));
      await tester.pump();
      await tester.tap(find.text('Jun'));
      await tester.pump();
      await tester.tap(find.text('invite'));
      await tester.pumpAndSettle();

      expect(find.text('try again'), findsOneWidget);
      expect(find.text("didn't go through"), findsOneWidget);
      // The panel is still open: a refusal is not a dead end.
      expect(find.textContaining('bakery'), findsOneWidget);

      await tester.tap(find.text('try again'));
      await tester.pumpAndSettle();

      expect(sent, [
        ['@mika:loaf.test', '@jun:loaf.test'],
        ['@jun:loaf.test'],
      ]);
    },
  );
}
