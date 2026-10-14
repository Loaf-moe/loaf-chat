import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/notify/channel_notifications.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/model/message_route.dart';
import 'package:loaf_native/ui/model/notice.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.loaf.chat/notify');
  final calls = <MethodCall>[];
  Object? Function(MethodCall)? answer;
  late FakeChime chime;

  setUp(() {
    calls.clear();
    answer = null;
    chime = FakeChime();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return answer?.call(call);
        });
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  Notice notice({bool sound = true}) => Notice(
    route: const MessageRoute('!r:x', r'$e'),
    sender: 'Ada',
    senderId: '@ada:x',
    place: '#general · Loaf',
    body: 'hi',
    avatarPath: '/tmp/a.png',
    sound: sound,
  );

  Future<void> fromNative(String method, Object? args) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, args),
            ),
            (_) {},
          );

  test('show sends every field', () async {
    answer = (c) => true;
    await ChannelDesktopNotifications(chime: chime).show(notice());
    expect(calls.single.method, 'show');
    expect(calls.single.arguments, {
      'roomId': '!r:x',
      'eventId': r'$e',
      'title': 'Ada in #general · Loaf',
      'body': 'hi',
      'sender': 'Ada',
      'senderId': '@ada:x',
      'place': '#general · Loaf',
      'avatarPath': '/tmp/a.png',
      'sound': true,
    });
    expect(chime.plays, 0, reason: 'the platform sounded it');
  });

  test('a platform that could not sound it: the app plays the chime', () async {
    answer = (c) => false;
    await ChannelDesktopNotifications(chime: chime).show(notice());
    expect(chime.plays, 1);
    await ChannelDesktopNotifications(chime: chime).show(notice(sound: false));
    expect(chime.plays, 1);
  });

  test(
    'a failing platform throws nothing, and the chime still plays',
    () async {
      answer = (c) => throw PlatformException(code: 'x');
      final logged = <Object>[];
      final n = ChannelDesktopNotifications(chime: chime, log: logged.add);
      await n.show(notice());
      await n.show(notice());
      expect(chime.plays, 2);
      expect(logged, hasLength(1));
    },
  );

  test('blocked, withdraw, prepare and openSettings', () async {
    answer = (c) => c.method == 'blocked' ? true : null;
    final n = ChannelDesktopNotifications(chime: chime);
    expect(await n.blocked(), isTrue);
    await n.withdraw('!r:x');
    await n.prepare();
    await n.openSystemSettings();
    expect(
      [for (final c in calls) c.method],
      ['blocked', 'withdraw', 'prepare', 'openSettings'],
    );
    expect(calls[1].arguments, {'roomId': '!r:x'});
  });

  test('retract sends room and event', () async {
    await ChannelDesktopNotifications(chime: chime)
        .retract(const MessageRoute('!r:x', r'$e'));
    expect(calls.single.method, 'retract');
    expect(calls.single.arguments, {'roomId': '!r:x', 'eventId': r'$e'});
  });

  test('no plugin (a platform without one): blocked is false', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    expect(await ChannelDesktopNotifications(chime: chime).blocked(), isFalse);
  });

  test(
    'the first listener says ready, and only then are held clicks wanted',
    () async {
      final n = ChannelDesktopNotifications(chime: chime);
      expect(calls, isEmpty);
      final clicks = <MessageRoute>[];
      n.clicks.listen(clicks.add);
      await pumpEventQueue();
      expect(calls.single.method, 'ready');
      await fromNative('click', {'roomId': '!r:x', 'eventId': r'$e'});
      await fromNative('click', {'roomId': 1});
      await pumpEventQueue();
      expect(clicks, [const MessageRoute('!r:x', r'$e')]);
    },
  );
}
