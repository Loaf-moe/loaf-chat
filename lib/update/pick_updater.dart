/// Which updater this copy of the app gets, decided once at launch by how
/// it was installed.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../ui/model/updater.dart';
import 'appimage_updater.dart';
import 'build_info.dart';
import 'dbus_flatpak_portal.dart';
import 'ed25519.dart';
import 'flatpak_updater.dart';
import 'release_feed.dart';
import 'sparkle_updater.dart';

enum UpdaterKind { none, sparkle, flatpak, appImage }

UpdaterKind chooseUpdater({
  required bool release,
  required int build,
  required TargetPlatform platform,
  required Map<String, String> environment,
}) {
  if (!release || build == 0) return UpdaterKind.none;
  bool has(String name) => (environment[name] ?? '').isNotEmpty;
  return switch (platform) {
    TargetPlatform.macOS => UpdaterKind.sparkle,
    // Flatpak first: its sandbox is what is really running.
    TargetPlatform.linux when has('FLATPAK_ID') => UpdaterKind.flatpak,
    TargetPlatform.linux when has('APPIMAGE') => UpdaterKind.appImage,
    _ => UpdaterKind.none,
  };
}

/// Call after vodozemac is initialised: the AppImage updater verifies with it.
Updater pickUpdater() {
  final environment = Platform.environment;
  switch (chooseUpdater(
    release: kReleaseMode,
    build: buildNumber,
    platform: defaultTargetPlatform,
    environment: environment,
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
      return AppImageUpdater(
        appImage: File(environment['APPIMAGE']!),
        build: buildNumber,
        feed: latestFeed,
        verify: ed25519Check(appImagePublicKey),
      )..start();
  }
}
