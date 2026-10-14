/// Desktop notifications outside Flatpak: the freedesktop notification
/// server (GNOME Shell, Plasma, dunst, mako…) over the session bus.
library;

import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:matrix/matrix.dart' show Logs;

import '../ui/model/chime.dart';
import '../ui/model/desktop_notifications.dart';
import '../ui/model/message_route.dart';
import '../ui/model/notice.dart';

class FdoNotifications implements DesktopNotifications {
  FdoNotifications({
    required this.chime,
    required this.soundFile,
    this.bus,
    void Function(Object error)? log,
  }) : _log = log ?? ((e) => Logs().w('[loaf] notification failed', e));

  static const _name = 'org.freedesktop.Notifications';

  final Chime chime;

  /// The chime as a file the server can play: the app's bundled asset.
  final String soundFile;

  /// Given only by tests; otherwise the session bus.
  final DBusClient? bus;
  final void Function(Object error) _log;
  var _logged = false;

  // Lazy so that building one, or reading `clicks`, opens no socket: only a
  // shown notice, or a listener on `clicks`, does.
  late final _bus = bus ?? DBusClient.session();

  late final _server = DBusRemoteObject(
    _bus,
    name: _name,
    path: DBusObjectPath('/org/freedesktop/Notifications'),
  );

  /// Asked once: a server doesn't change what it can do while it runs.
  Future<Set<String>>? _caps;

  /// Each notification up, by the id the server gave it.
  final _routes = <int, MessageRoute>{};
  late final _clicks = StreamController<MessageRoute>.broadcast(
    onListen: _listen,
  );
  StreamSubscription<DBusSignal>? _invoked;
  StreamSubscription<DBusSignal>? _closed;

  /// Only a success is kept: a server that isn't up yet (session start,
  /// a dunst restart) must be asked again next time.
  Future<Set<String>> _capabilities() => _caps ??= _server
      .callMethod(
        _name,
        'GetCapabilities',
        const [],
        replySignature: DBusSignature('as'),
      )
      .then((r) => r.returnValues.single.asStringArray().toSet())
      .catchError((Object e) {
        _caps = null;
        throw e;
      });

  /// Subscribes to the server's signals, once. The subscriptions send their
  /// match rules without anyone awaiting them, so with no session bus their
  /// failure would be an uncaught async error: the zone gives it to [_fail].
  void _listen() {
    runZonedGuarded(() {
      _invoked ??=
          DBusRemoteObjectSignalStream(
            object: _server,
            interface: _name,
            name: 'ActionInvoked',
            signature: DBusSignature('us'),
          ).listen((s) {
            final route = _routes[s.values[0].asUint32()];
            if (route != null && s.values[1].asString() == 'default') {
              _clicks.add(route);
            }
          }, onError: _fail);
      _closed ??= DBusRemoteObjectSignalStream(
        object: _server,
        interface: _name,
        name: 'NotificationClosed',
        signature: DBusSignature('uu'),
      ).listen((s) => _routes.remove(s.values[0].asUint32()), onError: _fail);
    }, (e, _) => _fail(e));
  }

  void _fail(Object error) {
    if (_logged) return;
    _logged = true;
    _log(error);
  }

  static String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  @override
  Future<void> prepare() async {}

  @override
  Future<void> show(Notice notice) async {
    var sounded = false;
    try {
      _listen();
      final caps = await _capabilities();
      final serverSounds = caps.contains('sound');
      // The same message again (read late, now with its text) replaces
      // its notification: the server answers with the id it was given.
      final replaces = _routes.entries
          .where((e) => e.value == notice.route)
          .map((e) => e.key)
          .firstOrNull;
      final reply = await _server.callMethod(_name, 'Notify', [
        const DBusString('Loaf Chat'),
        DBusUint32(replaces ?? 0),
        const DBusString('moe.loaf.chat'),
        DBusString(notice.title),
        DBusString(
          caps.contains('body-markup') ? _escape(notice.body) : notice.body,
        ),
        DBusArray.string(
          caps.contains('actions') ? const ['default', 'open'] : const [],
        ),
        DBusDict.stringVariant({
          'desktop-entry': const DBusString('moe.loaf.chat'),
          'category': const DBusString('im.received'),
          if (notice.sound && serverSounds) 'sound-file': DBusString(soundFile),
          if (!notice.sound) 'suppress-sound': const DBusBoolean(true),
          if (notice.avatarPath case final path?)
            'image-path': DBusString(Uri.file(path).toString()),
        }),
        const DBusInt32(-1),
      ], replySignature: DBusSignature('u'));
      _routes[reply.returnValues.single.asUint32()] = notice.route;
      sounded = notice.sound && serverSounds;
    } on Object catch (e) {
      _fail(e);
    }
    if (notice.sound && !sounded) await chime.play();
  }

  @override
  Future<void> withdraw(String roomId) => _close([
    for (final MapEntry(key: id, value: route) in _routes.entries)
      if (route.roomId == roomId) id,
  ]);

  @override
  Future<void> retract(MessageRoute route) => _close([
    for (final MapEntry(key: id, value: shown) in _routes.entries)
      if (shown == route) id,
  ]);

  Future<void> _close(List<int> ids) async {
    for (final id in ids) {
      _routes.remove(id);
      try {
        await _server.callMethod(_name, 'CloseNotification', [
          DBusUint32(id),
        ], replySignature: DBusSignature(''));
      } on Object catch (e) {
        _fail(e);
      }
    }
  }

  @override
  Stream<MessageRoute> get clicks => _clicks.stream;

  @override
  Future<bool> blocked() async => false;

  @override
  Future<void> openSystemSettings() async {}
}
