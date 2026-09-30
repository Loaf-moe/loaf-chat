import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/model/updater.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);
final _phone = TargetPlatformVariant.only(TargetPlatform.iOS);

Future<FakeUpdater> _pump(
  WidgetTester tester,
  UpdateState state, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final updater = FakeUpdater(state);
  addTearDown(updater.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: AppShell(updater: updater),
    ),
  );
  await tester.pumpAndSettle();
  return updater;
}

Finder _tile(String title) => find.byTooltip(title);

void main() {
  testWidgets('nothing shows while idle or preparing', variant: _mac, (
    tester,
  ) async {
    final updater = await _pump(tester, const UpdateIdle());
    expect(find.byIcon(LucideIcons.arrowDownToLine), findsNothing);
    updater.state = const UpdatePreparing();
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.arrowDownToLine), findsNothing);
  });

  testWidgets(
    'a ready update is a tile that names its version',
    variant: _mac,
    (tester) async {
      final updater = await _pump(tester, const UpdateIdle());
      updater.state = const UpdateReady('0.4.0');
      await tester.pumpAndSettle();
      expect(_tile('loaf chat 0.4.0 is ready'), findsOneWidget);
    },
  );

  testWidgets(
    'without a version it still says something is ready',
    variant: _mac,
    (tester) async {
      await _pump(tester, const UpdateReady(null));
      expect(_tile('a new loaf chat is ready'), findsOneWidget);
    },
  );

  testWidgets('restart asks the updater to restart', variant: _mac, (
    tester,
  ) async {
    final updater = await _pump(tester, const UpdateReady('0.4.0'));
    await tester.tap(_tile('loaf chat 0.4.0 is ready'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('restart'));
    await tester.pumpAndSettle();
    expect(updater.restarts, 1);
  });

  testWidgets(
    'later hides that version, and a newer one comes back',
    variant: _mac,
    (tester) async {
      final updater = await _pump(tester, const UpdateReady('0.4.0'));
      await tester.tap(_tile('loaf chat 0.4.0 is ready'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('later'));
      await tester.pumpAndSettle();
      expect(_tile('loaf chat 0.4.0 is ready'), findsNothing);
      expect(updater.restarts, 0);

      // Said again, it stays put away.
      updater.state = const UpdateReady('0.4.0');
      await tester.pumpAndSettle();
      expect(_tile('loaf chat 0.4.0 is ready'), findsNothing);

      // Something newer is news.
      updater.state = const UpdateReady('0.4.1');
      await tester.pumpAndSettle();
      expect(_tile('loaf chat 0.4.1 is ready'), findsOneWidget);
    },
  );

  testWidgets(
    'while applying there is no later and no live action',
    variant: _mac,
    (tester) async {
      final updater = await _pump(tester, const UpdateApplying('0.4.0'));
      await tester.tap(_tile('loaf chat 0.4.0 is ready'));
      await tester.pumpAndSettle();
      expect(find.text('later'), findsNothing);
      await tester.tap(find.text('restarting…'));
      await tester.pumpAndSettle();
      expect(updater.restarts, 0);
    },
  );

  testWidgets('a phone never shows it', variant: _phone, (tester) async {
    await _pump(tester, const UpdateReady('0.4.0'), size: const Size(390, 844));
    await tester.tap(find.byIcon(LucideIcons.menu));
    await tester.pumpAndSettle();
    expect(_tile('loaf chat 0.4.0 is ready'), findsNothing);
  });
}
