/// Each platform's own way of showing a file. The Swift end is
/// `darwin/loaf_media/Sources/loaf_media/LoafMediaPlugin.swift`.
library;

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'portal.dart';

abstract final class LoafMedia {
  static const _channel = MethodChannel('moe.loaf.chat/media');

  /// iOS: QLPreviewController. macOS: the shared QLPreviewPanel.
  static Future<void> quickLook(String path) =>
      _channel.invokeMethod<void>('quickLook', {'path': path});

  /// macOS: the app that opens files of [extension] by default, or null.
  static Future<String?> defaultAppName(String extension) =>
      _channel.invokeMethod<String>('defaultAppName', {'extension': extension});

  /// macOS: opens [path] in its default app.
  static Future<void> openWithDefaultApp(String path) =>
      _channel.invokeMethod<void>('openWithDefaultApp', {'path': path});

  /// Linux: the picture on the clipboard as PNG bytes, or null when it holds
  /// none. (The plugin only takes calls that carry arguments, hence the map.)
  static Future<Uint8List?> clipboardImage() =>
      _channel.invokeMethod<Uint8List>('clipboard.image', <String, Object?>{});

  /// Linux: the paths of the files copied in a file manager. Empty when the
  /// clipboard holds none.
  static Future<List<String>> clipboardFiles() async =>
      await _channel.invokeListMethod<String>(
        'clipboard.files',
        <String, Object?>{},
      ) ??
      const [];

  /// Linux: org.freedesktop.portal.OpenURI.OpenFile.
  static Future<void> openWithPortal(String path) async {
    final bus = sessionBus();
    try {
      await OpenUriPortal(bus).openFile(path);
    } finally {
      await bus.close();
    }
  }

  /// The bus the portal is on. Tests point it at a private one.
  @visibleForTesting
  static DBusClient Function() sessionBus = DBusClient.session;
}
