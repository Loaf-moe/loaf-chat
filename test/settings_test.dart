import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_devices.dart';
import 'package:loaf_native/ui/settings/devices.dart';
import 'package:loaf_native/ui/settings/settings_page.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

/// Opens settings as the app does with a backend that lists sessions and
/// signs out; either left out, its entry is left out too.
Future<void> _open(
  WidgetTester tester,
  Size size, {
  bool withDevices = true,
  VoidCallback? onSignOut,
  SettingsSection initial = SettingsSection.account,
}) async {
  final Devices? devices = withDevices ? MockDevices() : null;
  addTearDown(() => devices?.dispose());
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showSettings(
                context,
                devices: devices,
                onSignOut: onSignOut,
                initial: initial,
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
}

void main() {
  testWidgets('opens on the account, over the app', (tester) async {
    await _open(tester, const Size(1440, 900));

    expect(tester.takeException(), isNull);
    // Settings is a detour: the screen behind it is still mounted.
    expect(find.text('open'), findsOneWidget);
    expect(find.text('display name'.toUpperCase()), findsOneWidget);
  });

  testWidgets('wide shows nav beside detail', (tester) async {
    await _open(tester, const Size(1440, 900));

    // Both panes at once: the nav entry and the profile content.
    expect(find.text('devices'), findsOneWidget);
    expect(find.text('account'), findsWidgets);
  });

  testWidgets('narrow shows the nav, then the detail in place', (tester) async {
    await _open(tester, const Size(390, 844));

    expect(tester.takeException(), isNull);
    // Nav only — no detail beside it.
    expect(find.text('display name'.toUpperCase()), findsNothing);

    await tester.tap(find.text('account'));
    await tester.pumpAndSettle();

    // The detail replaced the nav inside the same card.
    expect(find.text('devices'), findsNothing);
    expect(find.text('display name'.toUpperCase()), findsOneWidget);
  });

  testWidgets('closing returns to the app', (tester) async {
    await _open(tester, const Size(1440, 900));

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(find.text('devices'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('close stays available inside a narrow section', (tester) async {
    await _open(tester, const Size(390, 844));
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);

    await tester.tap(find.text('account'));
    await tester.pumpAndSettle();

    // The close button belongs to the card, so entering a section must not
    // take it away — and back appears only now that there is a level to go
    // back to.
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('back steps out of a section before closing the card', (
    tester,
  ) async {
    await _open(tester, const Size(390, 844));
    await tester.tap(find.text('account'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    // Back to the nav, still inside settings. (The app stays mounted behind
    // the modal, so its button remains findable — that is the point of it.)
    expect(find.text('devices'), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);
    expect(find.byTooltip('Close'), findsOneWidget);
  });

  testWidgets('lists only sections that do something', (tester) async {
    await _open(tester, const Size(1440, 900), onSignOut: () {});

    for (final gone in [
      'appearance',
      'notifications',
      'voice & video',
      'stickers',
      'developer',
      'about',
    ]) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    expect(find.textContaining('not designed yet'), findsNothing);
    expect(find.text('devices'), findsOneWidget);
    expect(find.text('sign out'), findsOneWidget);
  });

  testWidgets('without devices, there is no devices entry', (tester) async {
    await _open(
      tester,
      const Size(1440, 900),
      withDevices: false,
      initial: SettingsSection.devices,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('devices'), findsNothing);
    // Asked for devices it can't show, it opens on the account instead.
    expect(find.text('display name'.toUpperCase()), findsOneWidget);
  });

  testWidgets('sign out shows only when it does something', (tester) async {
    await _open(tester, const Size(1440, 900));
    expect(find.text('sign out'), findsNothing);
  });

  testWidgets('sign out closes the card, then signs out', (tester) async {
    var signedOut = 0;
    await _open(tester, const Size(1440, 900), onSignOut: () => signedOut++);

    await tester.tap(find.text('sign out'));
    await tester.pumpAndSettle();

    expect(signedOut, 1);
    expect(find.text('devices'), findsNothing);
  });
}
