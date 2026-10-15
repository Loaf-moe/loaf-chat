/// What Dart and Sparkle's bridge say to each other, for Pigeon to turn into
/// `lib/update/macos/sparkle.g.dart` and `macos/Runner/Sparkle.g.swift`:
/// `mise run gen:pigeon`. Only macOS updates through Sparkle, so only Swift
/// is generated for.
library;

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/update/macos/sparkle.g.dart',
    swiftOut: 'macos/Runner/Sparkle.g.swift',
    dartPackageName: 'loaf_native',
  ),
)
/// How a check asked for by hand ended, as far as Sparkle goes: a find is
/// then still to be fetched, and [SparkleEvents] says when it has been.
enum SparkleCheck { upToDate, found, failed }

/// What Dart asks of Sparkle. The other end is `UpdaterBridge`.
@HostApi()
abstract class SparkleHost {
  /// Starts Sparkle, which then checks on its own schedule. Call once Dart
  /// listens to [SparkleEvents]: an event sent before would be lost.
  void start();

  /// Looks now. A session already under way answers this one too.
  @async
  SparkleCheck check();

  /// Installs the staged build and relaunches into it. Throws when nothing
  /// is staged.
  void restart();
}

/// What Sparkle tells Dart, as it happens.
@FlutterApi()
abstract class SparkleEvents {
  /// Nothing newer is known, or what was found could not be fetched.
  void idle();

  /// A newer build is being fetched and verified.
  void preparing();

  /// Staged and verified. [version] is null when the appcast names none.
  void ready(String? version);
}
