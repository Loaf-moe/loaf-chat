/// The app's short sounds: the chime for a message somewhere you aren't
/// looking, and a call's comings and goings. Played by the platform's own
/// player through `package:loaf_media`.
library;

import 'package:flutter/services.dart';
import 'package:loaf_media/loaf_media.dart';
import 'package:matrix/matrix.dart' show Logs;

/// Made by `tool/chime`; see `assets/sounds/`.
const chimeAsset = 'assets/sounds/chime.wav';

enum AppSound {
  /// A message somewhere you aren't looking.
  message(chimeAsset),

  /// You, or someone else, joining the call you are in.
  callJoined('assets/sounds/call_join.wav'),

  /// You, or someone else, leaving it.
  callLeft('assets/sounds/call_leave.wav');

  const AppSound(this.asset);

  /// See `assets/SOURCES.md`.
  final String asset;
}

abstract interface class Chime {
  /// Starts [sound]. Never throws: a sound that can't play isn't worth an
  /// error in front of you.
  Future<void> play([AppSound sound = AppSound.message]);
}

class NativeChime implements Chime {
  NativeChime({void Function(Object error)? log})
    : _log = log ?? ((e) => Logs().w('[loaf] chime failed', e));

  final void Function(Object error) _log;

  /// One line in the log, not one per message, on a machine that has no
  /// sound device.
  var _logged = false;

  @override
  Future<void> play([AppSound sound = AppSound.message]) async {
    try {
      await LoafMedia.playChime(sound.asset);
    } on MissingPluginException {
      // Android has no player yet; it has no chime either.
    } on Object catch (e) {
      if (_logged) return;
      _logged = true;
      _log(e);
    }
  }
}

/// Keeps what was played: for tests only. The app, mock backend included,
/// uses [NativeChime].
class FakeChime implements Chime {
  final played = <AppSound>[];

  int get plays => played.length;

  @override
  Future<void> play([AppSound sound = AppSound.message]) async =>
      played.add(sound);
}
