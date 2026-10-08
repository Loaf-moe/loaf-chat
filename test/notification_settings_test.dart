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

  test('a change is saved and read back', () async {
    final dir = await Directory.systemTemp.createTemp('notify');
    addTearDown(() => dir.delete(recursive: true));
    final store = FileNotificationStore(
      File('${dir.path}/n/notifications.json'),
    );
    final controller = await NotificationController.load(
      store,
      chime: FakeChime(),
    );
    controller.setSound(false);
    await pumpEventQueue();
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
}
