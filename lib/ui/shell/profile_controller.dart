/// Your presence and status message: one source of truth for the account
/// panel's picker and the settings account section.
library;

import 'package:flutter/foundation.dart';

import '../members/presence.dart';
import '../mock/fixtures.dart';

class ProfileController extends ChangeNotifier {
  ProfileController({
    this._choice = PresenceChoice.online,
    this._status = 'feeding the starter',
  });

  PresenceChoice _choice;
  String _status;

  PresenceChoice get choice => _choice;
  String get status => _status;

  /// You, as other people see you.
  Member get me =>
      currentUser.copyWith(presence: _choice.shown, statusMessage: _status);

  void choose(PresenceChoice choice) {
    if (choice == _choice) return;
    _choice = choice;
    notifyListeners();
  }

  /// Empty clears the status. No expiry: Matrix has none.
  void setStatus(String status) {
    final trimmed = status.trim();
    if (trimmed == _status) return;
    _status = trimmed;
    notifyListeners();
  }
}
