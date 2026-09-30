import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/members/presence.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/settings/account_section.dart';
import 'package:loaf_native/ui/shell/profile.dart';
import 'package:loaf_native/ui/shell/profile_controller.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/widgets/loaf_button.dart';

/// A profile the test drives by hand: a save it can hold or refuse.
class _Profile extends ChangeNotifier implements Profile {
  @override
  var displayName = 'Mochi';
  @override
  var status = 'baking';
  @override
  AvatarRef? avatar;
  @override
  var savingAccount = false;
  @override
  var uploadingAvatar = false;
  @override
  var presenceShared = true;

  /// The next save waits for this, then throws [failWith] if set.
  Completer<void>? hold;
  Object? failWith;
  final saved = <(String, String)>[];
  final avatars = <Uint8List?>[];

  @override
  Future<void> saveAccount({
    required String displayName,
    required String status,
  }) async {
    saved.add((displayName, status));
    savingAccount = true;
    notifyListeners();
    await hold?.future;
    savingAccount = false;
    final failure = failWith;
    if (failure != null) {
      notifyListeners();
      throw failure;
    }
    this.displayName = displayName;
    this.status = status;
    notifyListeners();
  }

  @override
  Future<void> setAvatar(Uint8List? png) async {
    avatars.add(png);
    avatar = png == null ? null : const AvatarRef('mxc://x/y');
    notifyListeners();
  }

  @override
  PresenceChoice get choice => PresenceChoice.online;
  @override
  Member get me => currentUser.copyWith(name: displayName, avatar: avatar);
  @override
  (Presence, String?)? presenceOf(String userId) => null;
  @override
  Future<void> choose(PresenceChoice choice) async {}
  @override
  Future<void> setStatus(String status) async {}
  @override
  void away(bool away) {}
}

Future<_Profile> _pump(WidgetTester tester, {_Profile? profile}) async {
  final fake = profile ?? _Profile();
  final controller = ProfileController(profile: fake);
  addTearDown(controller.dispose);
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(
        body: AccountSection(
          profile: controller,
          pickPicture: () async => Uint8List.fromList([1, 2, 3]),
        ),
      ),
    ),
  );
  return fake;
}

LoafButton _button(WidgetTester tester, String label) =>
    tester.widget<LoafButton>(find.widgetWithText(LoafButton, label));

bool _readOnly(WidgetTester tester, int i) =>
    tester.widget<TextField>(find.byType(TextField).at(i)).readOnly;

void main() {
  testWidgets('save is busy and fields are read-only while saving', (
    tester,
  ) async {
    final profile = await _pump(tester);
    profile.hold = Completer<void>();
    await tester.enterText(find.byType(TextField).first, 'Mochi 2');
    await tester.tap(find.text('save changes'));
    await tester.pump();

    expect(profile.saved, [('Mochi 2', 'baking')]);
    expect(_button(tester, 'saving…').onTap, isNull);
    expect(_button(tester, 'discard').onTap, isNull);
    expect(_readOnly(tester, 0), isTrue);
    expect(_readOnly(tester, 1), isTrue);

    profile.hold!.complete();
    await tester.pump();
    expect(_button(tester, 'save changes').onTap, isNotNull);
    expect(_readOnly(tester, 0), isFalse);
  });

  testWidgets('a failed name save says so and keeps your text', (tester) async {
    final profile = await _pump(tester);
    profile.failWith = const AccountSaveFailed(name: true, status: false);
    await tester.enterText(find.byType(TextField).first, 'Mochi 2');
    await tester.enterText(find.byType(TextField).at(1), 'napping');
    await tester.tap(find.text('save changes'));
    await tester.pump();
    await tester.pump();

    expect(find.text("couldn't save your name. try again?"), findsOneWidget);
    expect(find.text('Mochi 2'), findsOneWidget);
    expect(find.text('napping'), findsOneWidget);
    // Live again: trying again is the same tap.
    expect(_button(tester, 'save changes').onTap, isNotNull);
  });

  testWidgets('each failure has its own toast', (tester) async {
    final profile = await _pump(tester);
    for (final (failure, toast) in [
      (
        const AccountSaveFailed(name: true, status: true),
        "couldn't save your changes. try again?",
      ),
      (
        const AccountSaveFailed(name: false, status: true),
        "couldn't save your status. try again?",
      ),
    ]) {
      profile.failWith = failure;
      await tester.tap(find.text('save changes'));
      await tester.pump();
      await tester.pump();
      expect(find.text(toast), findsOneWidget);
    }
  });

  testWidgets('discard restores what the profile has', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField).first, 'Mochi 2');
    await tester.enterText(find.byType(TextField).at(1), 'napping');
    await tester.tap(find.text('discard'));
    await tester.pump();
    expect(find.text('Mochi'), findsWidgets);
    expect(find.text('baking'), findsOneWidget);
    expect(find.text('napping'), findsNothing);
  });

  testWidgets('remove picture is offered only with a picture', (tester) async {
    final profile = await _pump(tester);
    await tester.tap(find.byKey(const Key('change-picture')));
    await tester.pumpAndSettle();
    expect(find.text('choose a picture…'), findsOneWidget);
    expect(find.text('remove picture'), findsNothing);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    profile.avatar = const AvatarRef('mxc://x/y');
    profile.notifyListeners();
    await tester.pump();

    await tester.tap(find.byKey(const Key('change-picture')));
    await tester.pumpAndSettle();
    expect(find.text('remove picture'), findsOneWidget);

    await tester.tap(find.text('remove picture'));
    await tester.pumpAndSettle();
    expect(profile.avatars, [null]);
  });

  testWidgets('the badge can not be tapped mid-upload', (tester) async {
    final profile = await _pump(tester);
    profile.uploadingAvatar = true;
    profile.notifyListeners();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byKey(const Key('change-picture')));
    // The spinner never settles.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('choose a picture…'), findsNothing);
  });

  testWidgets('on a computer, right-click opens the menu', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _pump(tester);
      await tester.tap(
        find.byKey(const Key('change-picture')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('choose a picture…'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a picture that cannot be read toasts', (tester) async {
    final profile = await _pump(tester);
    await tester.tap(find.byKey(const Key('change-picture')));
    await tester.pumpAndSettle();
    // Three bytes are no image: the shrink refuses.
    await tester.runAsync(() async {
      await tester.tap(find.text('choose a picture…'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(
      find.text("couldn't change your picture. try again?"),
      findsOneWidget,
    );
    expect(profile.avatars, isEmpty);
  });

  testWidgets('presence chips hide when the server shares none', (
    tester,
  ) async {
    final profile = await _pump(tester);
    expect(find.text('invisible'), findsOneWidget);
    profile.presenceShared = false;
    profile.notifyListeners();
    await tester.pump();
    expect(find.text('invisible'), findsNothing);
    expect(find.text("this server doesn't share presence"), findsOneWidget);
  });
}
