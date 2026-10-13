import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/notify/channel_notifications.dart';
import 'package:loaf_native/notify/fdo_notifications.dart';
import 'package:loaf_native/notify/pick_notifications.dart';
import 'package:loaf_native/notify/portal_notifications.dart';
import 'package:loaf_native/notify/windows_notifications.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/model/message_route.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final chime = FakeChime();

  // Constructing opens no D-Bus socket and loads no DLL: each one makes its
  // client lazily. On a Mac a loaded Windows DLL would throw right here.
  Type? pick(TargetPlatform p, [Map<String, String> env = const {}]) =>
      pickDesktopNotifications(
        chime: chime,
        platform: p,
        environment: env,
        executable: '/app/loaf-chat',
      )?.runtimeType;

  test('each desktop gets its own; phones get none', () {
    expect(pick(TargetPlatform.macOS), ChannelDesktopNotifications);
    expect(pick(TargetPlatform.windows), WindowsDesktopNotifications);
    expect(pick(TargetPlatform.linux), FdoNotifications);
    expect(
      pick(TargetPlatform.linux, {'FLATPAK_ID': 'moe.loaf.chat'}),
      PortalNotifications,
    );
    expect(pick(TargetPlatform.iOS), isNull);
    expect(pick(TargetPlatform.android), isNull);
  });

  test('the chime file sits in the bundle beside the exe', () {
    expect(
      bundledChime('/app/loaf-chat'),
      '/app/data/flutter_assets/assets/sounds/chime.wav',
    );
  });

  test('a click brings the window forward before it is followed', () async {
    final clicks = StreamController<MessageRoute>();
    final order = <String>[];
    final routes = fronted(
      clicks.stream,
      front: () async => order.add('front'),
    );
    routes.listen((r) => order.add(r.roomId));
    clicks.add(const MessageRoute('!r', r'$e'));
    await pumpEventQueue();
    expect(order, ['front', '!r']);
  });

  test('a window that cannot come forward still follows the click', () async {
    final clicks = StreamController<MessageRoute>();
    final got = <MessageRoute>[];
    fronted(
      clicks.stream,
      front: () async => throw StateError('no'),
    ).listen(got.add);
    clicks.add(const MessageRoute('!r', r'$e'));
    await pumpEventQueue();
    expect(got, hasLength(1));
  });
}
