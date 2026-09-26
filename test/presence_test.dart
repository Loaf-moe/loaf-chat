import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:loaf_native/ui/emoji/emoji_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/members/member_list.dart';
import 'package:loaf_native/ui/members/presence_dot.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/shell/status_picker.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

Future<void> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
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

Iterable<Size> _dotSizes(WidgetTester tester, Finder within) => [
  for (final dot
      in find
          .descendant(of: within, matching: find.byType(PresenceDot))
          .evaluate())
    (dot.renderObject! as RenderBox).size,
];

Future<void> _debug(WidgetTester tester, String item) async {
  await tester.tap(find.byTooltip('Debug'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'with presence off on your server, no dot anywhere',
    variant: _desktop,
    (tester) async {
      await _pumpShell(tester);
      expect(
        _dotSizes(tester, find.byType(MemberList)),
        contains(isNot(Size.zero)),
      );

      await _debug(tester, 'turn presence off on this server');

      expect(
        _dotSizes(tester, find.byType(MemberList)),
        everyElement(Size.zero),
      );
      expect(
        _dotSizes(tester, find.byKey(const ValueKey('account-avatar'))),
        everyElement(Size.zero),
      );
    },
  );

  testWidgets(
    'with presence off, the status picker keeps only your status',
    variant: _desktop,
    (tester) async {
      await _pumpShell(tester);
      await _debug(tester, 'turn presence off on this server');

      await tester.tap(find.byKey(const ValueKey('account-avatar')));
      await tester.pumpAndSettle();

      expect(find.text("this server doesn't share presence"), findsOneWidget);
      // Short as it now is, it still opens above the avatar, not over it.
      final avatar = tester.getRect(
        find.byKey(const ValueKey('account-avatar')),
      );
      final popover = tester.getRect(find.byType(StatusPickerPopover));
      expect(popover.bottom, lessThanOrEqualTo(avatar.top));
      expect(find.text('do not disturb'), findsNothing);
      expect(find.text("what's cooking?"), findsOneWidget);
    },
  );

  testWidgets(
    "people on a server without presence show no dot",
    variant: _desktop,
    (tester) async {
      await _pumpShell(tester);

      await tester.tap(find.byTooltip('Add a space'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('explore public spaces'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('loaf.moe'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('matrix.org').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Bakers'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('join').last);
      await tester.pumpAndSettle();

      final remote = find.byKey(const ValueKey('member-@proofer:matrix.org'));
      expect(remote, findsOneWidget);
      expect(_dotSizes(tester, remote), everyElement(Size.zero));
      expect(tester.widget<Opacity>(remote).opacity, 1);
    },
  );

  testWidgets('escape closes the status popover', variant: _desktop, (
    tester,
  ) async {
    await _pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('account-avatar')));
    await tester.pumpAndSettle();
    expect(find.byType(StatusPickerPopover), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(StatusPickerPopover), findsNothing);
  });

  testWidgets('escape closes the emoji popover', variant: _desktop, (
    tester,
  ) async {
    await _pumpShell(tester);
    await tester.tap(find.byTooltip('Emoji'));
    await tester.pumpAndSettle();
    expect(find.byType(EmojiPicker), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(EmojiPicker), findsNothing);
  });
}
