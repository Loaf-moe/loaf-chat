/// Your presence and status message: one source of truth for the account
/// panel's picker and the settings account section. A view over a [Profile].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../members/presence.dart';
import '../mock/mock_profile.dart';
import '../model/models.dart';
import 'profile.dart';

/// Which write failed, so the toast can say so.
enum ProfileCall { presence, status }

class ProfileController extends ChangeNotifier {
  ProfileController({Profile? profile, this.onError})
    : _profile = profile ?? MockProfile(),
      _owns = profile == null {
    _profile.addListener(notifyListeners);
  }

  final Profile _profile;

  /// Only a profile made here is disposed here; the rooms own theirs.
  final bool _owns;

  /// Told when a [choose] or [setStatus] the server refused. Those stay
  /// `void` for the pickers, so the failure has nowhere else to go.
  final void Function(ProfileCall call, Object error)? onError;

  /// Whether your homeserver shares presence at all. When it doesn't,
  /// nobody's arrives and yours goes nowhere; only a status message
  /// survives.
  bool get presenceShared => _profile.presenceShared;

  /// Flips the mock's lever; a real profile hears it from the server.
  void togglePresenceShared() {
    final profile = _profile;
    if (profile is MockProfile) profile.togglePresenceShared();
  }

  PresenceChoice get choice => _profile.choice;
  String get status => _profile.status;

  /// You, as other people see you.
  Member get me => _profile.me;

  (Presence, String?)? presenceOf(String userId) => _profile.presenceOf(userId);

  void choose(PresenceChoice choice) =>
      _report(ProfileCall.presence, _profile.choose(choice));

  /// Automatic idle, from the shell's watcher.
  void away(bool away) => _profile.away(away);

  /// Empty clears the status. No expiry: Matrix has none.
  void setStatus(String status) =>
      _report(ProfileCall.status, _profile.setStatus(status.trim()));

  void _report(ProfileCall call, Future<void> future) {
    unawaited(
      future.catchError((Object error) {
        onError?.call(call, error);
      }),
    );
  }

  @override
  void dispose() {
    _profile.removeListener(notifyListeners);
    if (_owns) _profile.dispose();
    super.dispose();
  }
}
