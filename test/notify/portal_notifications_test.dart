import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/notify/portal_notifications.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/model/message_route.dart';
import 'package:loaf_native/ui/model/notice.dart';

const _iface = 'org.freedesktop.portal.Notification';
const _name = 'org.freedesktop.portal.Desktop';

/// Stands in for the Notification portal: a settable version, and a record
/// of AddNotification and RemoveNotification.
class _FakePortal extends DBusObject {
  _FakePortal(this.version)
    : super(DBusObjectPath('/org/freedesktop/portal/desktop'));
  final int version;
  final added = <(String, Map<String, DBusValue>)>[];
  final removed = <String>[];

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async =>
      interface == _iface && name == 'version'
      ? DBusGetPropertyResponse(DBusUint32(version))
      : DBusMethodErrorResponse.unknownProperty();

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != _iface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (call.name) {
      case 'AddNotification':
        added.add((
          call.values[0].asString(),
          call.values[1].asStringVariantDict(),
        ));
        return DBusMethodSuccessResponse();
      case 'RemoveNotification':
        removed.add(call.values[0].asString());
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  Future<void> invoke(String id, List<String> target) =>
      emitSignal(_iface, 'ActionInvoked', [
        DBusString(id),
        const DBusString('open'),
        DBusArray.variant([DBusArray.string(target)]),
      ]);
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

  Future<_FakePortal> serve(_FakePortal p) async {
    await serverSide.requestName(_name);
    await serverSide.registerObject(p);
    return p;
  }

  PortalNotifications make() => PortalNotifications(chime: chime, bus: appSide);

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('loaf-portal-test');
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

  test('version 2: the notice, its icon as bytes, the portal silent, and the app chime', () async {
    final p = await serve(_FakePortal(2));
    final avatar = File('${dir.path}/ada.png')..writeAsBytesSync([9, 9]);
    await make().show(_notice(avatar: avatar.path));
    final (id, fields) = p.added.single;
    expect(id, r'room:!r:x:$e');
    expect(fields['title'], const DBusString('Ada in #general · Loaf'));
    expect(fields['body'], const DBusString('hi'));
    expect(fields['default-action'], const DBusString('open'));
    expect(fields['category'], const DBusString('im.received'));
    final target = fields['default-action-target']!;
    expect(target.asStringArray().toList(), ['!r:x', r'$e']);
    final icon = fields['icon']! as DBusStruct;
    expect(icon.children.first, const DBusString('bytes'));
    expect(
      ((icon.children[1] as DBusVariant).value as DBusArray).children
          .map((b) => (b as DBusByte).value)
          .toList(),
      [9, 9],
    );
    expect(fields['sound'], const DBusString('silent'));
    expect(chime.plays, 1);
  });

  test('version 1: no sound field, and the app plays the chime', () async {
    final p = await serve(_FakePortal(1));
    await make().show(_notice());
    expect(p.added.single.$2.containsKey('sound'), isFalse);
    expect(chime.plays, 1);
  });

  test('a silent notice on version 2 stays silent', () async {
    final p = await serve(_FakePortal(2));
    await make().show(_notice(sound: false));
    expect(p.added.single.$2['sound'], const DBusString('silent'));
    expect(chime.plays, 0);
  });

  test('a portal not up at the first notice gets silent later', () async {
    final n = make();
    await n.show(_notice());
    expect(chime.plays, 1);
    final p = await serve(_FakePortal(2));
    await n.show(_notice());
    expect(p.added.single.$2['sound'], const DBusString('silent'));
    expect(chime.plays, 2);
  });

  test(
    'a click is a route, from the target even for a notice from a last run',
    () async {
      final p = await serve(_FakePortal(2));
      final n = make();
      final clicks = <MessageRoute>[];
      n.clicks.listen(clicks.add);
      // Listening sends the match rule without awaiting it; the bus answers
      // a ping on the same connection only once it has that rule.
      await appSide.ping();
      await p.invoke(r'room:!old:x:$z', ['!old:x', r'$z']);
      await pumpEventQueue();
      expect(clicks, [const MessageRoute('!old:x', r'$z')]);
    },
  );

  test('withdraw removes that room\'s notices', () async {
    final p = await serve(_FakePortal(2));
    final n = make();
    await n.show(_notice(room: '!a:x'));
    await n.show(_notice(room: '!b:x'));
    await n.withdraw('!a:x');
    expect(p.removed, [r'room:!a:x:$e']);
  });

  // A bus nobody listens on, as on a desktop with no session bus.
  DBusClient deadBus() =>
      DBusClient(DBusAddress.unix(path: '${dir.path}/no-such-bus'));

  test('reading clicks alone opens no bus', () async {
    final uncaught = <Object>[];
    final logged = <Object>[];
    await runZonedGuarded(() async {
      final n = PortalNotifications(
        chime: chime,
        bus: deadBus(),
        log: logged.add,
      );
      n.clicks;
      await pumpEventQueue();
      expect(logged, isEmpty, reason: 'nothing was attempted');
    }, (e, _) => uncaught.add(e));
    expect(uncaught, isEmpty);
  });

  test('listening with no bus leaks no uncaught error', () async {
    final uncaught = <Object>[];
    final logged = <Object>[];
    await runZonedGuarded(() async {
      final n = PortalNotifications(
        chime: chime,
        bus: deadBus(),
        log: logged.add,
      );
      final sub = n.clicks.listen((_) {});
      await pumpEventQueue();
      await sub.cancel();
    }, (e, _) => uncaught.add(e));
    expect(uncaught, isEmpty);
    expect(logged, hasLength(1), reason: 'logged once');
  });

  test('prepare, blocked and open settings ask nothing of the OS', () async {
    final logged = <Object>[];
    final n = PortalNotifications(
      chime: chime,
      bus: deadBus(),
      log: logged.add,
    );
    await n.prepare();
    expect(await n.blocked(), isFalse);
    await n.openSystemSettings();
    expect(logged, isEmpty);
  });
}
