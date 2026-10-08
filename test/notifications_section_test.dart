import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/settings/notification_settings.dart';
import 'package:loaf_native/ui/settings/notifications_section.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

void main() {
  testWidgets(
    'sound can be turned off and on; turning it on plays the chime once',
    (tester) async {
      final chime = FakeChime();
      final controller = await NotificationController.load(
        MemoryNotificationStore(),
        chime: chime,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: Scaffold(body: NotificationsSection(controller: controller)),
        ),
      );
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
}
