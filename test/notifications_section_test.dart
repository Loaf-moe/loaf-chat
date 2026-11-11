import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_profile.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/model/desktop_notifications.dart';
import 'package:loaf_native/ui/settings/notification_settings.dart';
import 'package:loaf_native/ui/settings/notifications_section.dart';
import 'package:loaf_native/ui/settings/settings_controls.dart';
import 'package:loaf_native/ui/shell/profile.dart';
import 'package:loaf_native/ui/shell/profile_controller.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/util/json_store.dart';

/// The mock's profile, with a choice the test can hold in flight.
class _Profile extends MockProfile {
  Completer<void>? hold;
  var busy = false;

  @override
  bool get settingChannelDefault => busy;

  @override
  Future<void> setChannelDefault(ChannelDefault level) async {
    busy = true;
    notifyListeners();
    await hold?.future;
    busy = false;
    await super.setChannelDefault(level);
    notifyListeners();
  }
}

Future<void> pumpSection(
  WidgetTester tester,
  NotificationController controller, {
  ProfileController? profile,
}) => tester.pumpWidget(
  MaterialApp(
    theme: loafDarkTheme(),
    home: Scaffold(
      body: NotificationsSection(controller: controller, profile: profile),
    ),
  ),
);

NotificationController soundController() => NotificationController(
  store: MemoryStore<NotificationSettings>(),
  chime: FakeChime(),
);

NotificationController desktopController(
  FakeDesktopNotifications desktop, {
  bool notifications = true,
}) => NotificationController(
  store: MemoryStore<NotificationSettings>(),
  chime: FakeChime(),
  desktop: desktop,
  settings: NotificationSettings(notifications: notifications),
);

/// The binding asserts debug variables are unset before teardowns run, so
/// the override is reset in a finally rather than an addTearDown.
Future<void> onPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  testWidgets(
    'sound can be turned off and on; turning it on plays the chime once',
    (tester) async {
      final chime = FakeChime();
      final controller = await NotificationController.load(
        MemoryStore<NotificationSettings>(),
        chime: chime,
      );
      await pumpSection(tester, controller);
      expect(find.text('sound'), findsOneWidget);

      await tester.tap(find.text('sound'));
      await tester.pump();
      expect(controller.sound, isFalse);
      expect(chime.plays, 0, reason: 'turning it off is silent');

      await tester.tap(find.text('sound'));
      await tester.pump();
      expect(controller.sound, isTrue);
      expect(chime.plays, 1, reason: 'turning it on lets you hear what it is');
    },
  );

  testWidgets('on a desktop: notifications and message text, which save', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.macOS, () async {
      final desktop = FakeDesktopNotifications();
      final c = desktopController(desktop);
      await pumpSection(tester, c);
      expect(find.text('notifications'), findsOneWidget);
      expect(find.text('show message text'), findsOneWidget);
      expect(
        find.text(
          'a soft chime for messages in other channels, and on notifications.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('show message text'));
      await tester.pump();
      expect(c.showText, isFalse);

      await tester.tap(find.text('notifications'));
      await tester.pump();
      expect(c.notifications, isFalse);
      await tester.tap(find.text('notifications'));
      await tester.pumpAndSettle();
      expect(c.notifications, isTrue);
      expect(desktop.prepared, 1, reason: 'turning it on gets it ready');
    });
  });

  testWidgets('on a phone: only sound', (tester) async {
    await onPlatform(TargetPlatform.iOS, () async {
      final c = NotificationController(
        store: MemoryStore<NotificationSettings>(),
        chime: FakeChime(),
      );
      await pumpSection(tester, c);
      expect(find.text('notifications'), findsNothing);
      expect(find.text('show message text'), findsNothing);
    });
  });

  testWidgets('when the OS blocks them, a line says so and opens settings', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.macOS, () async {
      try {
        final desktop = FakeDesktopNotifications()..isBlocked = true;
        await pumpSection(tester, desktopController(desktop));
        await tester.pumpAndSettle();
        expect(
          find.text('macos is blocking notifications from loaf chat.'),
          findsOneWidget,
        );
        await tester.tap(find.text('open system settings'));
        expect(desktop.settingsOpened, 1);

        // Back from System Settings with them allowed: the line goes.
        desktop.isBlocked = false;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('is blocking'), findsNothing);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    });
  });

  testWidgets('without a profile, nothing of the account shows', (
    tester,
  ) async {
    await pumpSection(tester, soundController());
    expect(find.text("EVERYWHERE YOU'RE SIGNED IN"), findsNothing);
    expect(find.text('all messages'), findsNothing);
  });

  testWidgets('the channel default shows the choice and saves the other', (
    tester,
  ) async {
    final profile = _Profile();
    final controller = ProfileController(profile: profile);
    addTearDown(controller.dispose);
    await pumpSection(tester, soundController(), profile: controller);
    expect(find.text("EVERYWHERE YOU'RE SIGNED IN"), findsOneWidget);
    expect(find.text('direct messages always notify.'), findsOneWidget);
    bool selected(String title) => tester
        .widget<SettingsChoice>(find.widgetWithText(SettingsChoice, title))
        .selected;
    expect(selected('all messages'), isTrue);
    expect(selected('mentions only'), isFalse);

    await tester.tap(find.text('mentions only'));
    await tester.pump();
    expect(profile.channelDefault, ChannelDefault.mentions);
    expect(selected('mentions only'), isTrue);
    expect(selected('all messages'), isFalse);
  });

  testWidgets('a choice in flight spins until it lands', (tester) async {
    final profile = _Profile()..hold = Completer();
    final controller = ProfileController(profile: profile);
    addTearDown(controller.dispose);
    await pumpSection(tester, soundController(), profile: controller);

    await tester.tap(find.text('mentions only'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    profile.hold!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(profile.channelDefault, ChannelDefault.mentions);
  });

  testWidgets('show message text is greyed while notifications are off', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.macOS, () async {
      final c = desktopController(
        FakeDesktopNotifications(),
        notifications: false,
      );
      await pumpSection(tester, c);
      await tester.tap(find.text('show message text'));
      await tester.pump();
      expect(c.showText, isTrue);
    });
  });
}
