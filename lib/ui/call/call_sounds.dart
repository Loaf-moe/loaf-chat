/// A call's comings and goings, heard: a sound when you join or leave, and
/// when someone else does. The rule is Element Call's, so both sound alike.
library;

import 'dart:async';

import '../model/chime.dart';
import 'calls.dart';

class CallSounds {
  CallSounds(
    this._calls,
    this._chime, {
    required this._soundOn,
    this._elapsed,
  }) {
    // A call already under way is where things start, not news.
    _take();
    _calls.addListener(_onChange);
  }

  final Calls _calls;
  final Chime _chime;
  final bool Function() _soundOn;

  /// The clock the gap between sounds is measured by; tests move it.
  final Duration Function()? _elapsed;
  final _watch = Stopwatch()..start();

  /// Past this many others (eight people, you included), people come and
  /// go too often to mark each.
  static const _crowd = 7;

  /// Several people arriving together sound once.
  static const _gap = Duration(milliseconds: 500);

  /// The call you are in, once it has gone live, and how many others it
  /// had when last looked at.
  String? _live;
  var _others = 0;
  final _last = <AppSound, Duration>{};

  /// The call you are in if it has gone live, and how many others it has.
  (String?, int) _now() {
    final session = _calls.session;
    final live =
        session != null &&
        (session.phase == CallPhase.live ||
            session.phase == CallPhase.reconnecting);
    return live
        ? (
            session.target.id,
            session.participants.where((p) => p.present).length,
          )
        : (null, 0);
  }

  void _take() {
    final (live, others) = _now();
    _live = live;
    _others = others;
  }

  void _onChange() {
    final (live, others) = _now();
    if (live != _live) {
      if (_live != null) _play(AppSound.callLeft);
      if (live != null) _play(AppSound.callJoined);
    } else if (live != null && others <= _crowd) {
      if (others > _others) _play(AppSound.callJoined);
      if (others < _others) _play(AppSound.callLeft);
    }
    _take();
  }

  void _play(AppSound sound) {
    if (!_soundOn()) return;
    final now = _elapsed?.call() ?? _watch.elapsed;
    final last = _last[sound];
    if (last != null && now - last < _gap) return;
    _last[sound] = now;
    unawaited(_chime.play(sound));
  }

  void dispose() => _calls.removeListener(_onChange);
}
