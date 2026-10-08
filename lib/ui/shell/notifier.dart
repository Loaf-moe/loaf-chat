/// What happens when a message arrives: nothing, the chime, a desktop
/// notification, or (a phone in the background) leaving it to push. The
/// table is the spec's "Notifier" section; this only decides and plays.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../model/arrival.dart';
import '../model/chime.dart';
import '../platform.dart';

enum NoticeAction { none, chime, desktopNotice, push }

/// [focused]: the app is in front and resumed. [open]: the message is in
/// the channel on screen, which marks it read. [desktop]: macOS, Windows
/// or Linux.
NoticeAction decide({
  required bool focused,
  required bool open,
  required bool desktop,
}) {
  if (focused) return open ? NoticeAction.none : NoticeAction.chime;
  return desktop ? NoticeAction.desktopNotice : NoticeAction.push;
}

class Notifier {
  Notifier({
    required Stream<Arrival> arrivals,
    required this.chime,
    required this.soundOn,
    required this.openRoom,
    bool Function()? focused,
    bool? desktop,
    Duration Function()? elapsed,
  }) : _focused = focused ?? _resumed,
       _desktop = desktop ?? isDesktop,
       _elapsed = elapsed ?? _clock {
    _sub = arrivals.listen(_on);
  }

  final Chime chime;
  final bool Function() soundOn;

  /// The room whose messages are on screen, or null.
  final String? Function() openRoom;
  final bool Function() _focused;
  final bool _desktop;
  final Duration Function() _elapsed;
  late final StreamSubscription<Arrival> _sub;

  /// A monotonic clock for the throttle: the wall clock can step backwards,
  /// which would hold the chime back until it caught up.
  static final Stopwatch _stopwatch = Stopwatch()..start();
  static Duration _clock() => _stopwatch.elapsed;

  /// When the chime last played, on that clock: messages within a second of
  /// it are the same moment, and get one chime.
  Duration? _lastChime;

  /// The same test the channel view uses before it marks anything read.
  static bool _resumed() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _on(Arrival arrival) {
    switch (decide(
      focused: _focused(),
      open: arrival.roomId == openRoom(),
      desktop: _desktop,
    )) {
      case NoticeAction.chime:
        _chime();
      case NoticeAction.desktopNotice:
        // Step D shows these.
        break;
      case NoticeAction.push:
        // Step E: the push gateway brings it.
        break;
      case NoticeAction.none:
        break;
    }
  }

  void _chime() {
    if (!soundOn()) return;
    final now = _elapsed();
    final last = _lastChime;
    if (last != null && now - last < const Duration(seconds: 1)) {
      return;
    }
    _lastChime = now;
    unawaited(chime.play());
  }

  void dispose() => unawaited(_sub.cancel());
}
