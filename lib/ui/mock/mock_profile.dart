/// [Profile] from fixtures: today's mock state, so the shell behaves as it
/// did before presence had a backend.
library;

import 'package:flutter/foundation.dart';

import '../members/presence.dart';
import '../shell/profile.dart';
import 'fixtures.dart';

class MockProfile extends ChangeNotifier implements Profile {
  MockProfile();

  @override
  PresenceChoice get choice => _choice;
  var _choice = PresenceChoice.online;

  @override
  String get status => _status;
  var _status = 'feeding the starter';

  /// A mock toggle: the debug lever for a server that shares nothing.
  @override
  bool get presenceShared => _presenceShared;
  var _presenceShared = true;

  void togglePresenceShared() {
    _presenceShared = !_presenceShared;
    notifyListeners();
  }

  @override
  String get displayName => _name;
  var _name = currentUser.name;

  @override
  AvatarRef? get avatar => _avatar;
  AvatarRef? _avatar = currentUser.avatar;

  @override
  bool get savingAccount => false;

  @override
  bool get uploadingAvatar => false;

  @override
  Member get me => currentUser.copyWith(
    name: _name,
    presence: _choice.shown,
    statusMessage: _status,
    avatar: _avatar,
  );

  @override
  Future<void> saveAccount({
    required String displayName,
    required String status,
  }) {
    final name = displayName.trim();
    final trimmed = status.trim();
    if (name.isNotEmpty && name != _name) _name = name;
    _status = trimmed;
    notifyListeners();
    return SynchronousFuture(null);
  }

  /// Nothing to upload to: a ref the mock can't draw keeps initials showing,
  /// but "remove picture" comes and goes honestly.
  @override
  Future<void> setAvatar(Uint8List? png) {
    _avatar = png == null ? null : AvatarRef('mock:${png.length}');
    notifyListeners();
    return SynchronousFuture(null);
  }

  /// Fixture rows already carry their presence, so there is nothing to add.
  @override
  (Presence, String?)? presenceOf(String userId) => null;

  /// Nothing on the wire to change.
  @override
  void away(bool away) {}

  @override
  Future<void> choose(PresenceChoice choice) {
    if (choice != _choice) {
      _choice = choice;
      notifyListeners();
    }
    return SynchronousFuture(null);
  }

  /// No expiry: Matrix has none.
  @override
  Future<void> setStatus(String status) {
    final trimmed = status.trim();
    if (trimmed != _status) {
      _status = trimmed;
      notifyListeners();
    }
    return SynchronousFuture(null);
  }
}
