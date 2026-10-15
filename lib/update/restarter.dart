/// Starting the new build and leaving the old one: the last step of every
/// update the app restarts into itself.
library;

import 'dart:io';

/// The real thing by default; tests extend it to watch instead.
class Restarter {
  const Restarter();

  /// Starts [executable] on its own, so it outlives this process.
  Future<void> launch(String executable) =>
      Process.start(executable, const [], mode: ProcessStartMode.detached);

  /// Ends this process.
  void quit() => exit(0);
}
