/// The part of `org.freedesktop.portal.Flatpak` the updater needs, as an
/// interface, so the updater is tested without a session bus.
library;

class UpdateCommits {
  const UpdateCommits({
    required this.running,
    required this.local,
    required this.remote,
  });

  /// The build this process is.
  final String running;

  /// The build a restart would start.
  final String local;

  /// The build the remote offers.
  final String remote;
}

abstract class FlatpakPortal {
  /// The portal's interface version. Throws when there is no portal.
  Future<int> version();

  /// Each update the portal notices. Listening starts its monitor.
  Stream<UpdateCommits> watch();

  /// Installs the remote build. True once it is installed, false when there
  /// was nothing newer to install; throws when the portal fails, or refuses
  /// because the build wants a new permission.
  Future<bool> update();

  /// Starts the newest installed build.
  Future<void> spawnLatest();

  Future<void> close();
}
