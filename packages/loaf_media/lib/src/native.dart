/// Each platform's own way of showing a file. The native ends are
/// `darwin/loaf_media/Sources/loaf_media/LoafMediaPlugin.swift`,
/// `linux/loaf_media_plugin.cc` and `windows/loaf_media_plugin.cpp`.
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

  /// macOS and Windows: the app that opens files of [extension] by default,
  /// or null.
  static Future<String?> defaultAppName(String extension) =>
      _channel.invokeMethod<String>('defaultAppName', {'extension': extension});

  /// macOS and Windows: opens [path] in its default app. On Windows, a file
  /// with none set asks which app to use, as Explorer does.
  static Future<void> openWithDefaultApp(String path) =>
      _channel.invokeMethod<void>('openWithDefaultApp', {'path': path});

  /// Plays a sound bundled as the Flutter asset [asset], through the
  /// platform's own player: System Sound Services, GStreamer or PlaySound.
  /// Returns once it has started.
  static Future<void> playChime(String asset) =>
      _channel.invokeMethod<void>('chime.play', {'asset': asset});

  /// Whether the clipboard holds a picture or files. It reads neither, so
  /// asking is cheap and, on iOS, shows no "Allow Paste" prompt. The three
  /// clipboard calls are for macOS, iOS and Linux, and carry a map since the
  /// Linux plugin only takes calls that have arguments.
  static Future<bool> clipboardHasFiles() async =>
      await _channel.invokeMethod<bool>('clipboard.has', <String, Object?>{}) ??
      false;

  /// The picture on the clipboard as PNG bytes, or null when it holds none.
  static Future<Uint8List?> clipboardImage() =>
      _channel.invokeMethod<Uint8List>('clipboard.image', <String, Object?>{});

  /// The paths of the files copied in a file manager. Empty when the
  /// clipboard holds none, and always on iOS.
  static Future<List<String>> clipboardFiles() async =>
      await _channel.invokeListMethod<String>(
        'clipboard.files',
        <String, Object?>{},
      ) ??
      const [];

  /// Windows: decodes a picture Flutter's own codecs refuse (HEIC, AVIF)
  /// with WIC, at most [maxWidth] wide. Premultiplied RGBA, as
  /// `decodeImageFromPixels` takes it. Throws if WIC can't either.
  static Future<DecodedImage> decodeImage(
    Uint8List bytes, {
    int? maxWidth,
  }) async {
    final decoded = await _channel.invokeMapMethod<String, Object?>(
      'image.decode',
      {'bytes': bytes, 'maxWidth': ?maxWidth},
    );
    if (decoded case {
      'width': final int width,
      'height': final int height,
      'pixels': final Uint8List pixels,
    }) {
      return DecodedImage(width, height, pixels);
    }
    throw PlatformException(code: 'image', message: 'nothing decoded');
  }

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

/// A picture as pixels: [pixels] is [width] × [height] premultiplied RGBA.
class DecodedImage {
  const DecodedImage(this.width, this.height, this.pixels);
  final int width;
  final int height;
  final Uint8List pixels;
}
