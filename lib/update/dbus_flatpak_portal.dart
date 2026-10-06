/// [FlatpakPortal] over the session bus. Kept thin: everything that decides
/// anything is in `flatpak_updater.dart`, where it can be tested.
library;

import 'dart:convert';

import 'package:dbus/dbus.dart';

import 'flatpak_portal.dart';

class DbusFlatpakPortal implements FlatpakPortal {
  static const _name = 'org.freedesktop.portal.Flatpak';
  static const _monitorInterface =
      'org.freedesktop.portal.Flatpak.UpdateMonitor';

  /// FLATPAK_SPAWN_FLAGS_LATEST_VERSION.
  static const _latestVersion = 2;

  final _bus = DBusClient.session();
  late final _portal = DBusRemoteObject(
    _bus,
    name: _name,
    path: DBusObjectPath('/org/freedesktop/portal/Flatpak'),
  );
  DBusRemoteObject? _monitor;

  @override
  Future<int> version() async => (await _portal.getProperty(
    _name,
    'version',
    signature: DBusSignature('u'),
  )).asUint32();

  Future<DBusRemoteObject> _open() async {
    final reply = await _portal.callMethod(_name, 'CreateUpdateMonitor', [
      DBusDict.stringVariant(const {}),
    ], replySignature: DBusSignature('o'));
    return _monitor = DBusRemoteObject(
      _bus,
      name: _name,
      path: reply.returnValues.single.asObjectPath(),
    );
  }

  Stream<Map<String, DBusValue>> _signals(
    DBusRemoteObject monitor,
    String name,
  ) => DBusRemoteObjectSignalStream(
    object: monitor,
    interface: _monitorInterface,
    name: name,
    signature: DBusSignature('a{sv}'),
  ).map((signal) => signal.values.single.asStringVariantDict());

  @override
  Stream<UpdateCommits> watch() async* {
    final monitor = _monitor ?? await _open();
    await for (final info in _signals(monitor, 'UpdateAvailable')) {
      yield UpdateCommits(
        running: info['running-commit']?.asString() ?? '',
        local: info['local-commit']?.asString() ?? '',
        remote: info['remote-commit']?.asString() ?? '',
      );
    }
  }

  @override
  Future<void> update() async {
    final monitor = _monitor ?? await _open();
    // Status: 0 running, 1 nothing to do, 2 done, 3 failed.
    final finished = _signals(
      monitor,
      'Progress',
    ).firstWhere((progress) => (progress['status']?.asUint32() ?? 0) != 0);
    try {
      await monitor.callMethod(_monitorInterface, 'Update', [
        const DBusString(''),
        DBusDict.stringVariant(const {}),
      ], replySignature: DBusSignature(''));
    } catch (_) {
      // Nobody will await `finished` now; an error on it later would be
      // unhandled.
      finished.ignore();
      rethrow;
    }
    final last = await finished;
    if (last['status']?.asUint32() != 2) {
      throw StateError(
        last['error_message']?.asString() ?? 'the portal did not update',
      );
    }
  }

  @override
  Future<void> spawnLatest() => _portal.callMethod(_name, 'Spawn', [
    _bytes('/'),
    DBusArray(DBusSignature('ay'), [_bytes('loaf-chat')]),
    DBusDict(DBusSignature('u'), DBusSignature('h'), const {}),
    DBusDict(DBusSignature('s'), DBusSignature('s'), const {}),
    const DBusUint32(_latestVersion),
    DBusDict.stringVariant(const {}),
  ], replySignature: DBusSignature('u'));

  /// The portal takes paths and arguments as NUL-terminated bytes.
  static DBusArray _bytes(String text) =>
      DBusArray.byte([...utf8.encode(text), 0]);

  @override
  Future<void> close() async {
    final monitor = _monitor;
    _monitor = null;
    try {
      await monitor?.callMethod(
        _monitorInterface,
        'Close',
        const [],
        replySignature: DBusSignature(''),
      );
    } finally {
      await _bus.close();
    }
  }
}
