import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/home/new_message_picker.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/shell/channel_list.dart';
import 'package:loaf_native/ui/shell/spaces_rail.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

final _mobile = TargetPlatformVariant.only(TargetPlatform.iOS);
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

const _phone = Size(390, 844);
const _wide = Size(1440, 900);

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
  if (size == _phone) {
    await tester.tap(find.byIcon(LucideIcons.menu));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byKey(SpacesRail.homeKey));
  await tester.pumpAndSettle();
}

Finder _picker() => find.byType(NewMessagePicker);
Finder _inPicker(Finder f) => find.descendant(of: _picker(), matching: f);
Finder _inList(String text) =>
    find.descendant(of: find.byType(ChannelList), matching: find.text(text));

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byTooltip('New message'));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String name) async {
  await tester.tap(_inPicker(find.text(name)).first);
  await tester.pumpAndSettle();
}

Future<void> _go(WidgetTester tester, String label) async {
  await tester.tap(_inPicker(find.text(label)));
  await tester.pumpAndSettle();
}

void main() {
  group('the picker', () {
    testWidgets('is a dialog on a computer', variant: _desktop, (tester) async {
      await _pumpShell(tester, _wide);
      await _openPicker(tester);

      expect(_picker(), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget);
    });

    testWidgets('is a sheet on a phone', variant: _mobile, (tester) async {
      await _pumpShell(tester, _phone);
      await _openPicker(tester);

      expect(_picker(), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets("lists a person's existing conversations under them", (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      await _openPicker(tester);

      final sam = find.byKey(const ValueKey('person-@sam'));
      expect(
        find.descendant(of: sam, matching: find.textContaining('active')),
        findsNWidgets(2),
      );
    });

    testWidgets('finds someone by their full id', (tester) async {
      await _pumpShell(tester, _wide);
      await _openPicker(tester);

      await tester.enterText(
        _inPicker(find.byType(TextField)),
        '@crust:matrix.org',
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('person-@crust:matrix.org')),
        findsOneWidget,
      );
    });
  });

  testWidgets('picking someone clears the search for the next', (
    tester,
  ) async {
    await _pumpShell(tester, _wide);
    await _openPicker(tester);

    await tester.enterText(_inPicker(find.byType(TextField)), 'theo');
    await tester.pumpAndSettle();
    await _pick(tester, 'Theo Crust');

    final field = tester.widget<TextField>(_inPicker(find.byType(TextField)));
    expect(field.controller!.text, isEmpty);
    // Unpicking isn't deleting anything.
    expect(_inPicker(find.byTooltip('Remove')), findsOneWidget);
    expect(_inPicker(find.text('Pim Focaccia')), findsOneWidget);
  });

  group('starting a conversation', () {
    testWidgets('someone you already talk to opens that DM, not a new one', (
      tester,
    ) async {
      await _pumpShell(tester, _wide);
      final rows = find.byKey(const ValueKey('channel-dm-sam'));
      await _openPicker(tester);

      await _pick(tester, 'Sam Poolish');
      await _go(tester, 'open');

      expect(_picker(), findsNothing);
      expect(rows, findsOneWidget);
      expect(find.text('sorry, hands in dough. later?'), findsOneWidget);
    });

    testWidgets('someone new gets a DM that waits for them', (tester) async {
      await _pumpShell(tester, _wide);
      await _openPicker(tester);

      await _pick(tester, 'Theo Crust');
      await _go(tester, 'message');

      expect(_inList('Theo Crust'), findsOneWidget);
      expect(
        find.text('waiting for Theo Crust to join. you can already write.'),
        findsOneWidget,
      );
    });

    testWidgets('several new people start a group', (tester) async {
      await _pumpShell(tester, _wide);
      await _openPicker(tester);

      await _pick(tester, 'Theo Crust');
      await _pick(tester, 'Pim Focaccia');
      await _go(tester, 'start group');

      expect(_inList('Theo, Pim'), findsOneWidget);
    });

    testWidgets('exactly a group you have opens it', (tester) async {
      await _pumpShell(tester, _wide);
      await _openPicker(tester);

      await _pick(tester, 'Mika Rye');
      await _pick(tester, 'Jun Levain');
      await _pick(tester, 'Sam Poolish');
      await _go(tester, 'open weekend crew');

      expect(find.text('bake-along saturday? i have too much flour'), findsOne);
    });
  });

  group('duplicate DMs in Home', () {
    testWidgets('show one row per person, counting every unread', (
      tester,
    ) async {
      await _pumpShell(tester, _wide);

      expect(_inList('Sam Poolish'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('channel-dm-sam')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('keep older ones a menu away', variant: _desktop, (
      tester,
    ) async {
      await _pumpShell(tester, _wide);

      await tester.tap(_inList('Sam Poolish'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Older conversations'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('active').first);
      await tester.pumpAndSettle();

      expect(
        find.text('did you ever try the rye sour from that book?'),
        findsOneWidget,
      );
    });
  });
}
