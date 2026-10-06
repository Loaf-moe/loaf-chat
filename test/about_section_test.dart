import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/updater.dart';
import 'package:loaf_native/ui/settings/about_section.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

Future<void> _show(
  WidgetTester tester,
  Updater updater, {
  String v = '0.2.0',
}) => tester.pumpWidget(
  MaterialApp(
    theme: loafDarkTheme(),
    home: Scaffold(
      body: AboutSection(updater: updater, version: v),
    ),
  ),
);

void main() {
  testWidgets('shows the version, and no button when nothing updates', (
    tester,
  ) async {
    await _show(tester, const NoUpdater());
    expect(find.text('version 0.2.0'), findsOneWidget);
    expect(find.text('check for updates'), findsNothing);
  });

  testWidgets('a hand-made build says so', (tester) async {
    await _show(tester, const NoUpdater(), v: '');
    expect(find.text('a build made by hand'), findsOneWidget);
  });

  testWidgets('checking and finding nothing says so', (tester) async {
    final updater = FakeUpdater();
    await _show(tester, updater);
    await tester.tap(find.text('check for updates'));
    await tester.pump();
    expect(updater.checks, 1);
    expect(find.text("you're on the newest loaf chat."), findsOneWidget);
  });

  testWidgets('a failed check offers to try again', (tester) async {
    final updater = FakeUpdater()..nextCheck = UpdateCheck.failed;
    await _show(tester, updater);
    await tester.tap(find.text('check for updates'));
    await tester.pump();
    expect(find.text('try again'), findsOneWidget);
  });

  testWidgets('a found update offers the restart', (tester) async {
    final updater = FakeUpdater()..nextCheck = UpdateCheck.ready;
    await _show(tester, updater);
    await tester.tap(find.text('check for updates'));
    await tester.pump();
    expect(find.text('loaf chat 0.3.0 is ready.'), findsOneWidget);
    await tester.tap(find.text('restart to update'));
    expect(updater.restarts, 1);
  });
}
