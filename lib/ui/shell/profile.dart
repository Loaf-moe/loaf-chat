/// Your presence and status, and what is known of everyone else's. The
/// shell reads it through `ProfileController`; [MockProfile] plays it from
/// fixtures and `MatrixProfile` talks to the server.
library;

import 'package:flutter/foundation.dart';

import '../members/presence.dart';
import '../model/models.dart';

/// Do not disturb is two writes (presence and the push rule) and one landed
/// without the other. The profile has settled on what stuck; the shell asks
/// whether to try again.
class HalfApplied implements Exception {
  const HalfApplied();

  @override
  String toString() => 'HalfApplied: do not disturb only half-applied';
}

/// Saving the name and the status together, and part of it didn't land.
/// The flags say which part; the rest did.
class AccountSaveFailed implements Exception {
  const AccountSaveFailed({required this.name, required this.status});

  final bool name;
  final bool status;

  @override
  String toString() => 'AccountSaveFailed(name: $name, status: $status)';
}

abstract interface class Profile implements Listenable {
  PresenceChoice get choice;
  String get status;

  /// The name others see for you, as the server last had it.
  String get displayName;

  /// Your picture, or null for initials.
  AvatarRef? get avatar;

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

  /// Saves the name and the status together; throws [AccountSaveFailed]
  /// naming what didn't save. Unchanged fields aren't sent.
  Future<void> saveAccount({
    required String displayName,
    required String status,
  });

  /// PNG bytes, or null to remove. One upload at a time.
  Future<void> setAvatar(Uint8List? png);

  bool get savingAccount;
  bool get uploadingAvatar;

  /// Automatic idle: nobody is at the device (backgrounded, or no input for
  /// a while). Only shows while the choice is online; never changes
  /// [choice], never throws, and a server that refuses it is not reported.
  void away(bool away);

  void dispose();
}
