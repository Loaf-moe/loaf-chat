/// Your presence and status, and what is known of everyone else's. The
/// shell reads it through `ProfileController`; [MockProfile] plays it from
/// fixtures and `MatrixProfile` talks to the server.
library;

import 'package:flutter/foundation.dart';

import '../members/presence.dart';
import '../model/models.dart';

abstract interface class Profile implements Listenable {
  PresenceChoice get choice;
  String get status;

  /// Whether your homeserver shares presence at all.
  bool get presenceShared;

  /// You, as others see you.
  Member get me;

  /// Someone else's presence and status as last heard, or null when there is
  /// nothing to add and the row's own presence stands: never heard, or a
  /// backend with no presence of its own.
  (Presence, String?)? presenceOf(String userId);

  /// Throws when the server refuses; [choice] is then back where it was,
  /// unless a later choice has been made.
  Future<void> choose(PresenceChoice choice);

  /// Empty clears it.
  Future<void> setStatus(String status);

  void dispose();
}
