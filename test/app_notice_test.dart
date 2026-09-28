import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/shell/app_notice.dart';
import 'package:loaf_native/ui/shell/spaces_rail.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

final _mobile = TargetPlatformVariant.only(TargetPlatform.iOS);
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

Future<void> _pumpRail(WidgetTester tester, List<AppNotice> notices) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerLeft,
          child: SpacesRail(
            spaces: mockSpaces,
            selectedSpaceId: mockSpaces.first.id,
            onSelect: (_) {},
            notices: notices,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('notices sit at the bottom of the rail, below the spaces', (
    tester,
  ) async {
    await _pumpRail(tester, [AppNotice.verify(onAction: () {})]);

    final tile = tester.getRect(find.byTooltip('verify this session'));
    final addSpace = tester.getRect(find.byTooltip('Add a space'));
    expect(tile.top, greaterThan(addSpace.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('on a phone a notice opens as a sheet', variant: _mobile, (
    tester,
  ) async {
    var verified = false;
    await _pumpRail(tester, [
      AppNotice.verify(onAction: () => verified = true),
    ]);

    await tester.tap(find.byTooltip('verify this session'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.textContaining('encrypted messages'), findsOneWidget);
    await tester.tap(find.text('verify'));
    await tester.pumpAndSettle();
    expect(verified, isTrue);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('on a computer a notice opens as a popover', variant: _desktop, (
    tester,
  ) async {
    await _pumpRail(tester, [AppNotice.verify(onAction: () {})]);

    await tester.tap(find.byTooltip('verify this session'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.textContaining('encrypted messages'), findsOneWidget);
    final card = tester.getRect(find.textContaining('encrypted messages'));
    final tile = tester.getRect(find.byTooltip('verify this session'));
    expect(card.left, greaterThan(tile.right), reason: 'opens beside the rail');
  });

  testWidgets(
    "a computer notice's card is gone before its action opens a panel",
    variant: _desktop,
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      late BuildContext rootContext;
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                rootContext = context;
                return Align(
                  alignment: Alignment.centerLeft,
                  child: SpacesRail(
                    spaces: mockSpaces,
                    selectedSpaceId: mockSpaces.first.id,
                    onSelect: (_) {},
                    notices: [
                      AppNotice.verify(
                        onAction: () => showDialog<void>(
                          context: rootContext,
                          builder: (_) => const Text('panel open'),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('verify this session'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('verify'));
      // Pumps in small steps until the panel is open, so a panel that opens
      // early — while the popover's own exit animation is still running —
      // is caught rather than smoothed over by one big pump that settles
      // past both.
      for (
        var i = 0;
        i < 40 && find.text('panel open').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(find.text('panel open'), findsOneWidget);
      expect(find.textContaining('encrypted messages'), findsNothing);
    },
  );

  testWidgets('verification cannot be put off', (tester) async {
    await _pumpRail(tester, [AppNotice.verify(onAction: () {})]);

    await tester.tap(find.byTooltip('verify this session'));
    await tester.pumpAndSettle();

    // Ignoring it silently costs you encrypted history.
    expect(find.text('later'), findsNothing);
  });

  testWidgets('an update can be put off', variant: _desktop, (tester) async {
    var dismissed = false;
    await _pumpRail(tester, [
      AppNotice.update(
        version: '0.3.0',
        onAction: () {},
        onDismiss: () => dismissed = true,
      ),
    ]);

    await tester.tap(find.byTooltip('loaf 0.3.0 is ready'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('later'));
    await tester.pumpAndSettle();

    expect(dismissed, isTrue);
  });

  testWidgets('setting up recovery cannot be put off', (tester) async {
    await _pumpRail(tester, [AppNotice.setUpRecovery(onAction: () {})]);
    await tester.tap(find.byTooltip('set up recovery'));
    await tester.pumpAndSettle();
    expect(find.text('later'), findsNothing);
    expect(find.text('set up'), findsOneWidget);
  });

  testWidgets('a new recovery key cannot be put off', (tester) async {
    await _pumpRail(tester, [AppNotice.newKey(onAction: () {}, making: true)]);
    await tester.tap(find.byTooltip('your new recovery key'));
    await tester.pumpAndSettle();
    expect(
      find.text("it's being made — you'll need to save it"),
      findsOneWidget,
    );
    expect(find.text('later'), findsNothing);
    expect(find.text('show'), findsOneWidget);
  });
}
