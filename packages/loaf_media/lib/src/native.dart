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
