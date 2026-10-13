/// Which desktop notifications this platform gets, and the clicks they
/// send, made to bring the window forward first.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:window_to_front/window_to_front.dart';

import '../ui/model/chime.dart';
import '../ui/model/desktop_notifications.dart';
import '../ui/model/message_route.dart';
import 'channel_notifications.dart';
import 'fdo_notifications.dart';
import 'portal_notifications.dart';
import 'windows_notifications.dart';

DesktopNotifications? pickDesktopNotifications({
  required Chime chime,
  TargetPlatform? platform,
  Map<String, String>? environment,
  String? executable,
}) {
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.macOS => ChannelDesktopNotifications(chime: chime),
    TargetPlatform.windows => WindowsDesktopNotifications(chime: chime),
    // Flatpak's portal plays the chime itself; the daemon outside it needs a file.
    TargetPlatform.linux
        when (environment ?? Platform.environment).containsKey('FLATPAK_ID') =>
      PortalNotifications(chime: chime),
    TargetPlatform.linux => FdoNotifications(
      chime: chime,
      soundFile: bundledChime(executable ?? Platform.resolvedExecutable),
    ),
    _ => null,
  };
}

/// Where Flutter bundles the chime on Linux: `data/flutter_assets` beside
/// the exe.
String bundledChime(String executable) => [
  File(executable).parent.path,
  'data',
  'flutter_assets',
  chimeAsset,
].join(Platform.pathSeparator);

/// [clicks], each brought to the front before it is followed. One stream
/// for the app's life: a shell that opens later listens again.
Stream<MessageRoute> fronted(
  Stream<MessageRoute> clicks, {
  Future<void> Function()? front,
}) => clicks.asyncMap((route) async {
  try {
    await (front ?? WindowToFront.activate)();
  } on Object {
    // A window that can't come forward still opens the message.
  }
  return route;
}).asBroadcastStream();
