/// What the real updaters share: a state, and listeners told when it moves.
library;

import 'package:flutter/foundation.dart';

import '../ui/model/updater.dart';

abstract class StateUpdater extends ChangeNotifier implements Updater {
  UpdateState _state = const UpdateIdle();
  bool _disposed = false;

  @override
  UpdateState get state => _state;

  /// Does nothing after [dispose]: downloads and platform calls finish
  /// whenever they finish, and may find the updater gone.
  @protected
  void move(UpdateState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
