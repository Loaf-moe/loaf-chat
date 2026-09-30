import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_devices.dart';
import 'package:loaf_native/ui/settings/devices.dart';
import 'package:loaf_native/ui/settings/devices_section.dart';
import 'package:loaf_native/ui/settings/settings_page.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/verify/incoming_verification.dart';
import 'package:loaf_native/ui/verify/verifier.dart';

/// A server that can't be reached the first time, and reads as [_devices]
/// after. Signing out asks for a password and then waits on [release].
class _HandDevices extends ChangeNotifier implements Devices {
  _HandDevices({this.failLoads = 0, this.holdBeforeAsking = false});

  /// signOut waits on [asking] without ever calling onAuth.
  final bool holdBeforeAsking;
  final asking = Completer<bool>();

  int failLoads;
  var loads = 0;
  final release = Completer<void>();
  var asked = 0;
  final _devices = const [
    LoafDevice(id: 'ME', name: 'this one', current: true, verified: true),
    LoafDevice(id: 'OTHER', name: 'other one', current: false, verified: true),
  ];
  List<LoafDevice>? _list;

  @override
  List<LoafDevice>? get list => _list;

  @override
  Future<void> load() async {
    loads++;
    if (failLoads > 0) {
      failLoads--;
      throw Exception('offline');
    }
    _list = _devices;
    notifyListeners();
  }

  @override
  Future<void> rename(String id, String name) async {}

  @override
  Future<bool> signOut(
    String id, {
    required void Function(AuthChallenge) onAuth,
  }) async {
    if (holdBeforeAsking) return asking.future;
    final done = Completer<bool>();
    onAuth(_Held(this, done));
    return done.future;
  }
}

class _Held implements AuthChallenge {
  _Held(this._devices, this._done);

  final _HandDevices _devices;
  final Completer<bool> _done;

  @override
  AuthKind get kind => AuthKind.password;

  @override
  bool get retry => false;

  @override
  void password(String password) {
    _devices.asked++;
    unawaited(_devices.release.future.then((_) => _done.complete(true)));
  }

  @override
  void openBrowser() {}

  @override
  void browserFinished() {}

  @override
  void cancel() => _done.complete(false);
}

Future<void> _pump(
  WidgetTester tester,
  Devices devices, {
  Size size = const Size(1000, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      home: Scaffold(body: DevicesSection(devices: devices)),
    ),
  );
  await tester.pumpAndSettle();
}

final _computer = TargetPlatformVariant.only(TargetPlatform.macOS);

void main() {
  testWidgets('this device is first, then newest', (tester) async {
    await _pump(tester, MockDevices());
    double y(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(y('loaf on this mac'), lessThan(y('element on phone')));
    expect(y('element on phone'), lessThan(y('unknown session')));
    expect(find.textContaining('this device'), findsOneWidget);
    expect(find.text('last seen 2 hours ago'), findsNothing);
    expect(find.textContaining('last seen 2 hours ago'), findsOneWidget);
    expect(find.textContaining('last seen 30 days ago'), findsOneWidget);
    expect(find.text('unverified'), findsOneWidget);
    expect(find.text('verify it from that device'), findsOneWidget);
  });

  testWidgets('a failed load offers try again', (tester) async {
    final devices = _HandDevices(failLoads: 1);
    await _pump(tester, devices);
    expect(find.text("couldn't load your devices"), findsOneWidget);
    await tester.tap(find.text('try again'));
    await tester.pumpAndSettle();
    expect(find.text("couldn't load your devices"), findsNothing);
    expect(find.text('other one'), findsOneWidget);
    expect(devices.loads, 2);
  });

  testWidgets('renaming inline on a computer', variant: _computer, (
    tester,
  ) async {
    final devices = MockDevices();
    await _pump(tester, devices);
    expect(find.byType(SelectableText), findsWidgets);

    await tester.tap(find.text('element on phone'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    // Escape puts it back.
    await tester.enterText(find.byType(TextField), 'kitchen tablet');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('element on phone'), findsOneWidget);

    await tester.tap(find.text('element on phone'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'kitchen tablet');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    // Held still while the save is on its way.
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    await tester.pump(MockDevices.answerDelay);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('kitchen tablet'), findsOneWidget);
    expect(devices.list!.any((d) => d.name == 'kitchen tablet'), isTrue);
  });

  testWidgets('renaming on a phone opens a sheet', (tester) async {
    final devices = MockDevices();
    await _pump(tester, devices, size: const Size(400, 900));
    expect(find.byType(SelectableText), findsNothing);
    await tester.tap(find.text('element on phone'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'kitchen tablet');
    await tester.tap(find.text('save'));
    await tester.pump(MockDevices.answerDelay);
    await tester.pumpAndSettle();
    expect(find.text('kitchen tablet'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('signing out walks confirm, auth, then closes', (tester) async {
    final devices = MockDevices();
    await _pump(tester, devices, size: const Size(400, 900));
    // The current device has no sign out of its own: two others do.
    expect(find.text('sign out'), findsNWidgets(2));
    await tester.tap(find.text('sign out').first);
    await tester.pumpAndSettle();

    expect(find.text('sign out element on phone?'), findsOneWidget);
    expect(
      find.text("it'll need to sign in again to read anything."),
      findsOneWidget,
    );
    expect(find.text('keep it'), findsOneWidget);
    await tester.tap(find.text('sign out').last);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.text("confirm it's you before element on phone is signed out."),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'hunter2');
    await tester.pump();
    await tester.tap(find.text('continue'));
    await tester.pump(MockDevices.answerDelay);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('element on phone'), findsNothing);
    expect(devices.list!.length, 2);
  });

  testWidgets('keeping it closes the panel and changes nothing', (
    tester,
  ) async {
    final devices = MockDevices();
    await _pump(tester, devices, size: const Size(400, 900));
    await tester.tap(find.text('sign out').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('keep it'));
    await tester.pumpAndSettle();
    expect(find.text('keep it'), findsNothing);
    expect(devices.list!.length, 3);
  });

  testWidgets('no cancel while signing out', (tester) async {
    final devices = _HandDevices();
    await _pump(tester, devices, size: const Size(400, 900));
    await tester.tap(find.text('sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('sign out').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'right');
    await tester.pump();
    await tester.tap(find.text('continue'));
    await tester.pump();
    expect(devices.asked, 1);

    // The answer is on its way: nothing offers to put it back.
    expect(find.text('keep it'), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    // Nor does the barrier: it can't dismiss a locked panel.
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.text('checking…'), findsOneWidget);

    devices.release.complete();
    await tester.pumpAndSettle();
    expect(find.text('checking…'), findsNothing);
  });

  testWidgets('no cancel in the signing out step itself', (tester) async {
    final devices = _HandDevices(holdBeforeAsking: true);
    await _pump(tester, devices, size: const Size(400, 900));
    await tester.tap(find.text('sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('sign out').last);
    await tester.pump();

    expect(find.text('signing out…'), findsOneWidget);
    expect(find.text('keep it'), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    // Neither the barrier nor back puts it away.
    await tester.tapAt(const Offset(200, 20));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('signing out…'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('signing out…'), findsOneWidget);

    devices.asking.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('signing out…'), findsNothing);
  });

  testWidgets('settings opens on the devices section', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final devices = MockDevices();
    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettings(
              context,
              initial: SettingsSection.devices,
              devices: devices,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('loaf on this mac'), findsOneWidget);
  });

  testWidgets('not me opens devices', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: loafLightTheme(),
        home: Scaffold(
          body: NotMeStep(onClose: () {}, onOpenDevices: () => opened++),
        ),
      ),
    );
    expect(
      find.text(
        'someone may be signed in as you. change your password, and sign '
        'that device out in settings.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('open devices'));
    expect(opened, 1);
  });
}
