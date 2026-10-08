/// The chime: one short sound for a message somewhere you aren't looking.
/// Played by the platform's own player through `package:loaf_media`.
library;

import 'package:flutter/services.dart';
import 'package:loaf_media/loaf_media.dart';
import 'package:matrix/matrix.dart' show Logs;

/// Made by `tool/chime`; see `assets/sounds/`.
const chimeAsset = 'assets/sounds/chime.wav';

abstract interface class Chime {
  /// Starts the chime. Never throws: a sound that can't play isn't worth
  /// an error in front of you.
  Future<void> play();
}

class NativeChime implements Chime {
  NativeChime({void Function(Object error)? log})
    : _log = log ?? ((e) => Logs().w('[loaf] chime failed', e));

  final void Function(Object error) _log;

  /// One line in the log, not one per message, on a machine that has no
  /// sound device.
  var _logged = false;

  @override
  Future<void> play() async {
    try {
      await LoafMedia.playChime(chimeAsset);
    } on MissingPluginException {
      // Android has no player yet; it has no chime either.
    } on Object catch (e) {
      if (_logged) return;
      _logged = true;
      _log(e);
    }
  }
}

/// Counts plays: for tests only. The app, mock backend included, uses
/// [NativeChime].
class FakeChime implements Chime {
  int plays = 0;

  @override
  Future<void> play() async => plays++;
}
