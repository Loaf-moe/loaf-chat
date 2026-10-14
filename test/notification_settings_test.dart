import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/settings/notification_settings.dart';

void main() {
  test('sound is on unless turned off', () {
    expect(const NotificationSettings().sound, isTrue);
    expect(NotificationSettings.fromJson({'sound': false}).sound, isFalse);
    expect(NotificationSettings.fromJson({'sound': 'loud'}).sound, isTrue);
    expect(NotificationSettings.fromJson('junk').sound, isTrue);
  });

  test('the file store reads back what it saved', () async {
    final dir = await Directory.systemTemp.createTemp('notify');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/n/notifications.json');
    await FileNotificationStore(file)
        .save(const NotificationSettings(sound: false));
    final back = await FileNotificationStore(file).load();
    expect(back?.sound, isFalse);
  });

  test('a change goes to the store', () async {
    // The memory store saves synchronously, so there is no write to wait on.
    final store = MemoryNotificationStore();
    final controller = await NotificationController.load(
      store,
      chime: FakeChime(),
    );
    controller.setSound(false);
    expect(store.saved?.sound, isFalse);
    final again = await NotificationController.load(store, chime: FakeChime());
    expect(again.sound, isFalse);
  });

  test('an unreadable file reads as the defaults', () async {
    final dir = await Directory.systemTemp.createTemp('notify');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/notifications.json')
      ..writeAsStringSync('{nope');
    expect(await FileNotificationStore(file).load(), isNull);
  });

  test('setting the same value notifies no one', () async {
    final controller = await NotificationController.load(
      MemoryNotificationStore(),
      chime: FakeChime(),
    );
    var heard = 0;
    controller.addListener(() => heard++);
    controller.setSound(true);
    expect(heard, 0);
    controller.setSound(false);
    expect(heard, 1);
  });

  test('notifications and message text are on unless turned off', () {
    const s = NotificationSettings();
    expect(s.notifications, isTrue);
    expect(s.showText, isTrue);
    expect(
      NotificationSettings.fromJson(const {'sound': false}).notifications,
      isTrue,
    );
    final off = NotificationSettings.fromJson(const {
      'notifications': false,
      'showText': false,
    });
    expect(off.notifications, isFalse);
    expect(off.showText, isFalse);
    expect(off.sound, isTrue);
  });

  test('every field round-trips through the file store', () async {
    final dir = Directory.systemTemp.createTempSync('loaf-notify-settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = FileNotificationStore(File('${dir.path}/notifications.json'));
    const saved = NotificationSettings(
      sound: false,
      notifications: false,
      showText: false,
    );
    await store.save(saved);
    expect(await store.load(), saved);
  });

  test(
    'turning notifications or message text off notifies and saves',
    () async {
      final store = MemoryNotificationStore();
      final c = NotificationController(store: store, chime: FakeChime());
      var heard = 0;
      c.addListener(() => heard++);
      c.setNotifications(false);
      c.setShowText(false);
      await pumpEventQueue();
      expect(heard, 2);
      expect(c.notifications, isFalse);
      expect(c.showText, isFalse);
      expect(
        store.saved,
        const NotificationSettings(notifications: false, showText: false),
      );
      c.setShowText(false);
      expect(heard, 2, reason: 'the same value again is no change');
    },
  );
}
