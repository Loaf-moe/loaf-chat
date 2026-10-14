/// Desktop notifications inside Flatpak: the Notification portal, which
/// needs no permission in the manifest.
///
/// The portal's own sound would take the chime as a file descriptor nested
/// in a struct, which dbus 0.8 can't send (it writes the fd index
/// unaligned). So the app plays the chime itself, and the portal is told to
/// stay silent.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';
import 'package:matrix/matrix.dart' show Logs;

import '../ui/model/chime.dart';
import '../ui/model/desktop_notifications.dart';
import '../ui/model/message_route.dart';
import '../ui/model/notice.dart';

class PortalNotifications implements DesktopNotifications {
  PortalNotifications({
    required this.chime,
    this.bus,
    void Function(Object error)? log,
  }) : _log = log ?? ((e) => Logs().w('[loaf] notification failed', e));

  static const _iface = 'org.freedesktop.portal.Notification';

  final Chime chime;

  /// Given only by tests; otherwise the session bus.
  final DBusClient? bus;

  final void Function(Object error) _log;
  var _logged = false;

  // Lazy so that building one, or reading `clicks`, opens no socket: only a
  // shown notice, or a listener on `clicks`, does.
  late final _bus = bus ?? DBusClient.session();

  late final _portal = DBusRemoteObject(
    _bus,
    name: 'org.freedesktop.portal.Desktop',
    path: DBusObjectPath('/org/freedesktop/portal/desktop'),
  );

  /// The portal's interface version; 2 takes a `sound`. Kept only once read.
  int? _version;
  final _shown = <String, MessageRoute>{};
  late final _clicks = StreamController<MessageRoute>.broadcast(
    onListen: _listen,
  );
  StreamSubscription<DBusSignal>? _invoked;

  /// A portal that isn't up yet, or can't be read, counts as version 1 for
  /// this call only: the next notice asks again, so the sound comes later.
  Future<int> _portalVersion() async {
    final known = _version;
    if (known != null) return known;
    try {
      final v = await _portal.getProperty(
        _iface,
        'version',
        signature: DBusSignature('u'),
      );
      return _version = v.asUint32();
    } on Object {
      return 1;
    }
  }

  /// Subscribes to the portal's signal, once. The subscription sends its
  /// match rule without anyone awaiting it, so with no session bus its
  /// failure would be an uncaught async error: the zone gives it to [_fail].
  void _listen() {
    runZonedGuarded(() {
      _invoked ??=
          DBusRemoteObjectSignalStream(
            object: _portal,
            interface: _iface,
            name: 'ActionInvoked',
            signature: DBusSignature('ssav'),
          ).listen((s) {
            if (s.values[1].asString() != 'open') return;
            final route =
                _shown[s.values[0].asString()] ?? _target(s.values[2]);
            if (route != null) _clicks.add(route);
          }, onError: _fail);
    }, (e, _) => _fail(e));
  }

  /// The default action's target, [room, event]: how a click on a notice
  /// left from an earlier run still finds its message.
  static MessageRoute? _target(DBusValue parameter) {
    final params = parameter.asVariantArray().toList();
    if (params.isEmpty) return null;
    final ids = params.first.asStringArray().toList();
    return ids.length == 2 ? MessageRoute(ids[0], ids[1]) : null;
  }

  void _fail(Object error) {
    if (_logged) return;
    _logged = true;
    _log(error);
  }

  static String _id(MessageRoute r) => 'room:${r.roomId}:${r.eventId}';

  @override
  Future<void> prepare() async {}

  @override
  Future<void> show(Notice notice) async {
    try {
      _listen();
      final version = await _portalVersion();
      Uint8List? icon;
      if (notice.avatarPath case final avatar?) {
        try {
          icon = await File(avatar).readAsBytes();
        } on FileSystemException {
          // A picture gone by now is no reason to lose the words.
          icon = null;
        }
      }
      final id = _id(notice.route);
      await _portal.callMethod(_iface, 'AddNotification', [
        DBusString(id),
        DBusDict.stringVariant({
          'title': DBusString(notice.title),
          'body': DBusString(notice.body),
          'default-action': const DBusString('open'),
          'default-action-target': DBusArray.string([
            notice.route.roomId,
            notice.route.eventId,
          ]),
          if (version >= 2) 'category': const DBusString('im.received'),
          if (icon != null)
            'icon': DBusStruct([
              const DBusString('bytes'),
              DBusVariant(DBusArray.byte(icon)),
            ]),
          // The app's chime follows below: keep the backend's own off.
          if (version >= 2) 'sound': const DBusString('silent'),
        }),
      ], replySignature: DBusSignature(''));
      _shown[id] = notice.route;
    } on Object catch (e) {
      _fail(e);
    }
    if (notice.sound) await chime.play();
  }

  @override
  Future<void> withdraw(String roomId) => _remove([
    for (final MapEntry(key: id, value: route) in _shown.entries)
      if (route.roomId == roomId) id,
  ]);

  @override
  Future<void> retract(MessageRoute route) => _remove([_id(route)]);

  Future<void> _remove(List<String> ids) async {
    for (final id in ids) {
      _shown.remove(id);
      try {
        await _portal.callMethod(_iface, 'RemoveNotification', [
          DBusString(id),
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
