/// The account's signed-in sessions, as settings shows them. [MockDevices]
/// plays them from fixtures and `MatrixDevices` asks the server.
library;

import 'package:flutter/foundation.dart';

import '../verify/verifier.dart';

@immutable
class LoafDevice {
  const LoafDevice({
    required this.id,
    required this.name,
    required this.current,
    required this.verified,
    this.lastSeen,
    this.lastIp,
  });

  final String id;

  /// The server's display name, or the id when it has none.
  final String name;

  /// This device, which signs out with the button at the foot of settings.
  final bool current;
  final bool verified;
  final DateTime? lastSeen;
  final String? lastIp;
}

abstract interface class Devices implements Listenable {
  /// Null until the first load; throws are the caller's to show.
  List<LoafDevice>? get list;

  Future<void> load();

  Future<void> rename(String id, String name);

  /// False when [onAuth]'s challenge was cancelled; nothing changed then.
  Future<bool> signOut(
    String id, {
    required void Function(AuthChallenge) onAuth,
  });

  void dispose();
}
