/// Which updater this copy of the app gets, decided once at launch by how
/// it was installed.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'updater.dart';
import 'linux/appimage_updater.dart';
import 'feed/build_info.dart';
import 'linux/dbus_flatpak_portal.dart';
import 'feed/ed25519.dart';
import 'linux/flatpak_updater.dart';
import 'feed/release_feed.dart';
import 'macos/sparkle_updater.dart';
import 'windows/windows_updater.dart';

enum UpdaterKind { none, sparkle, flatpak, appImage, windows }

UpdaterKind chooseUpdater({
  required bool release,
  required int build,
  required TargetPlatform platform,
  required Map<String, String> environment,
  required bool installedBySetup,
}) {
  if (!release || build == 0) return UpdaterKind.none;
  bool has(String name) => (environment[name] ?? '').isNotEmpty;
  return switch (platform) {
    TargetPlatform.macOS => UpdaterKind.sparkle,
    // Flatpak first: its sandbox is what is really running.
    TargetPlatform.linux when has('FLATPAK_ID') => UpdaterKind.flatpak,
    TargetPlatform.linux when has('APPIMAGE') => UpdaterKind.appImage,
    // Only what Setup put in place: never a developer's build folder.
    TargetPlatform.windows when installedBySetup => UpdaterKind.windows,
    _ => UpdaterKind.none,
  };
}

/// Call after vodozemac is initialised: the AppImage updater verifies with it.
Updater pickUpdater() {
  final environment = Platform.environment;
  final install = File(Platform.resolvedExecutable).parent;
  switch (chooseUpdater(
    release: kReleaseMode,
    build: buildNumber,
    platform: defaultTargetPlatform,
    environment: environment,
    // Setup's uninstall log sits beside the executable it installed.
    installedBySetup:
        defaultTargetPlatform == TargetPlatform.windows &&
        File(p.join(install.path, 'unins000.dat')).existsSync(),
  )) {
    case UpdaterKind.none:
      return const NoUpdater();
    case UpdaterKind.sparkle:
      return SparkleUpdater();
    case UpdaterKind.flatpak:
      final updater = FlatpakUpdater(
        portal: DbusFlatpakPortal(),
        version: () async {
          final client = http.Client();
          try {
            return (await fetchRelease(client, latestFeed)).version;
          } finally {
            client.close();
          }
        },
      );
      unawaited(updater.start());
      return updater;
    case UpdaterKind.appImage:
      final updater = AppImageUpdater(
        appImage: File(environment['APPIMAGE']!),
        build: buildNumber,
        feed: latestFeed,
        verify: ed25519Check(releasePublicKey),
      );
      unawaited(updater.start());
      return updater;
    case UpdaterKind.windows:
      final updater = WindowsUpdater(
        installation: install,
        build: buildNumber,
        feed: latestFeed,
        verify: ed25519Check(releasePublicKey),
      );
      unawaited(updater.start());
      return updater;
  }
}
