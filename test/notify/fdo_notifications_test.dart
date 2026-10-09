import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/notify/fdo_notifications.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/model/message_route.dart';
import 'package:loaf_native/ui/model/notice.dart';

const _iface = 'org.freedesktop.Notifications';

/// Stands in for a notification server: records Notify and
/// CloseNotification, and says what it can do.
class _FakeServer extends DBusObject {
  _FakeServer(this.caps)
    : super(DBusObjectPath('/org/freedesktop/Notifications'));

  final List<String> caps;
  final notified = <List<DBusValue>>[];
  final closed = <int>[];
  var _next = 1;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != _iface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (call.name) {
      case 'GetCapabilities':
        return DBusMethodSuccessResponse([DBusArray.string(caps)]);
      case 'Notify':
        notified.add(call.values);
        return DBusMethodSuccessResponse([DBusUint32(_next++)]);
      case 'CloseNotification':
        closed.add(call.values.single.asUint32());
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  Future<void> invoke(int id, String action) =>
      emitSignal(_iface, 'ActionInvoked', [DBusUint32(id), DBusString(action)]);
}

Notice _notice({
  String room = '!r:x',
  String body = 'hi',
  bool sound = true,
  String? avatar,
}) => Notice(
  route: MessageRoute(room, r'$e'),
  sender: 'Ada',
  senderId: '@ada:x',
  place: '#general · Loaf',
  body: body,
  sound: sound,
  avatarPath: avatar,
);

void main() {
  late Directory dir;
  late DBusServer server;
  late DBusClient serverSide;
  late DBusClient appSide;
  late FakeChime chime;

  Future<_FakeServer> serve(List<String> caps) async {
    final s = _FakeServer(caps);
    await serverSide.requestName(_iface);
    await serverSide.registerObject(s);
    return s;
  }

  FdoNotifications make() =>
      FdoNotifications(chime: chime, soundFile: '/app/chime.wav', bus: appSide);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('loaf-fdo-test');
    server = DBusServer();
    final address = await server.listenAddress(DBusAddress.unix(dir: dir));
    serverSide = DBusClient(address, authClient: DBusAuthClient(uid: '0'));
    appSide = DBusClient(address, authClient: DBusAuthClient(uid: '0'));
    chime = FakeChime();
  });

  tearDown(() async {
    await appSide.close();
    await serverSide.close();
    await server.close();
    dir.deleteSync(recursive: true);
  });

  test(
    'notifies with the desktop entry, the sound file, and a default action',
    () async {
      final s = await serve(['actions', 'body', 'sound']);
      await make().show(_notice(avatar: '/tmp/a b.png'));
      final v = s.notified.single;
      expect(v[0], const DBusString('Loaf Chat'));
      expect(v[2], const DBusString('moe.loaf.chat'));
      expect(v[3], const DBusString('Ada in #general · Loaf'));
      expect(v[4], const DBusString('hi'));
      expect(v[5], DBusArray.string(['default', 'open']));
      final hints = v[6].asStringVariantDict();
      expect(hints['desktop-entry'], const DBusString('moe.loaf.chat'));
      expect(hints['sound-file'], const DBusString('/app/chime.wav'));
      expect(
        hints['image-path'],
        DBusString(Uri.file('/tmp/a b.png').toString()),
      );
      expect(v[7], const DBusInt32(-1));
      expect(chime.plays, 0);
    },
  );

  test('a server without sound: the app plays the chime', () async {
    final s = await serve(['actions', 'body']);
    await make().show(_notice());
    expect(
      s.notified.single[6].asStringVariantDict().containsKey('sound-file'),
      isFalse,
    );
    expect(chime.plays, 1);
  });

  test('a silent notice asks the server to keep quiet', () async {
    final s = await serve(['actions', 'body', 'sound']);
    await make().show(_notice(sound: false));
    final hints = s.notified.single[6].asStringVariantDict();
    expect(hints['suppress-sound'], const DBusBoolean(true));
    expect(hints.containsKey('sound-file'), isFalse);
    expect(chime.plays, 0);
  });

  test('the body is escaped for a markup server', () async {
    final s = await serve(['body', 'body-markup']);
    await make().show(_notice(body: '<b>hi</b> & co'));
    expect(
      s.notified.single[4],
      const DBusString('&lt;b&gt;hi&lt;/b&gt; &amp; co'),
    );
  });

  test('a server without actions gets none', () async {
    final s = await serve(['body']);
    await make().show(_notice());
    expect(s.notified.single[5], DBusArray.string([]));
  });

  test('a click on the default action is a route', () async {
    final s = await serve(['actions', 'body']);
    final n = make();
    final clicks = <MessageRoute>[];
    n.clicks.listen(clicks.add);
    await n.show(_notice());
    await s.invoke(1, 'default');
    await s.invoke(1, 'something-else');
    await s.invoke(99, 'default');
    await pumpEventQueue();
    expect(clicks, [const MessageRoute('!r:x', r'$e')]);
  });

  test('withdraw closes that room\'s notifications only', () async {
    final s = await serve(['actions', 'body']);
    final n = make();
    await n.show(_notice(room: '!a:x'));
    await n.show(_notice(room: '!b:x'));
    await n.show(_notice(room: '!a:x'));
    await n.withdraw('!a:x');
    expect(s.closed, unorderedEquals([1, 3]));
    await n.withdraw('!a:x');
    expect(s.closed, hasLength(2), reason: 'nothing left to close');
  });

  test('no server at all: nothing throws, and the chime still plays', () async {
    final logged = <Object>[];
    final n = FdoNotifications(
      chime: chime,
      soundFile: '/app/chime.wav',
      bus: appSide,
      log: logged.add,
    );
    await n.show(_notice());
    await n.show(_notice());
    expect(chime.plays, 2);
    expect(logged, hasLength(1), reason: 'logged once');
  });

  test('a server that arrives late is used by the next show', () async {
    final n = make();
    await n.show(_notice());
    expect(chime.plays, 1);
    final s = await serve(['actions', 'body']);
    await n.show(_notice(sound: false));
    expect(s.notified, hasLength(1));
  });
}
