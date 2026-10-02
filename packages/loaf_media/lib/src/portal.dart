/// The desktop portal's OpenURI, over D-Bus: how a sandboxed Linux app hands
/// a file to whatever the person opens such files with.
library;

import 'dart:io';

import 'package:dbus/dbus.dart';

/// The portal answered with an error, such as no app for this type.
class PortalError implements Exception {
  const PortalError(this.name, this.message);

  /// The D-Bus error name.
  final String name;
  final String? message;

  @override
  String toString() => message == null ? name : '$name: $message';
}

class OpenUriPortal {
  OpenUriPortal(DBusClient bus)
    : _portal = DBusRemoteObject(
        bus,
        name: 'org.freedesktop.portal.Desktop',
        path: DBusObjectPath('/org/freedesktop/portal/desktop'),
      );

  static const _interface = 'org.freedesktop.portal.OpenURI';

  final DBusRemoteObject _portal;

  /// Opens [path] in its default app. The file goes over as a descriptor,
  /// not a path: inside a sandbox the portal could not see the path.
  Future<void> openFile(String path) async {
    final file = await File(path).open();
    try {
      await _portal.callMethod(_interface, 'OpenFile', [
        // No parent window: a Flutter window has no portal handle to give.
        const DBusString(''),
        DBusUnixFd(ResourceHandle.fromFile(file)),
        DBusDict.stringVariant(const {}),
      ], replySignature: DBusSignature('o'));
    } on DBusMethodResponseException catch (e) {
      final values = e.response.values;
      throw PortalError(
        e.errorName,
        values.isNotEmpty && values.first is DBusString
            ? values.first.asString()
            : null,
      );
    } finally {
      // The bus has sent its own copy of the descriptor by now.
      await file.close();
    }
  }
}
