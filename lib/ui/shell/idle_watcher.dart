/// Automatic idle: tells the profile when nobody is at the device. Phones
/// are away while backgrounded; computers after a quiet spell with no
/// pointer or keyboard input. See "Automatic idle" in the phase 6 spec.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../platform.dart';

class IdleWatcher extends StatefulWidget {
  const IdleWatcher({
    super.key,
    required this.onAway,
    required this.child,
    this.after = const Duration(minutes: 10),
    @visibleForTesting this.desktop,
  });

  final ValueChanged<bool> onAway;
  final Widget child;

  /// How long a computer waits without input.
  final Duration after;

  /// Tests pick the platform; otherwise [isDesktop] says.
  final bool? desktop;

  @override
  State<IdleWatcher> createState() => _IdleWatcherState();
}

class _IdleWatcherState extends State<IdleWatcher> with WidgetsBindingObserver {
  Timer? _timer;
  var _away = false;

  bool get _computer => widget.desktop ?? isDesktop;

  @override
  void initState() {
    super.initState();
    if (_computer) {
      HardwareKeyboard.instance.addHandler(_onKey);
      _restart();
    } else {
      WidgetsBinding.instance.addObserver(this);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Said only on a change, so the profile isn't asked the same thing twice.
  void _set(bool away) {
    if (away == _away) return;
    _away = away;
    widget.onAway(away);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _set(true);
      case AppLifecycleState.resumed:
        _set(false);
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        // Inactive is a passing state (a system sheet, a task switcher).
        break;
    }
  }

  bool _onKey(KeyEvent event) {
    _input();
    // Never consumes: the watcher only listens.
    return false;
  }

  void _input() {
    _set(false);
    _restart();
  }

  void _restart() {
    _timer?.cancel();
    _timer = Timer(widget.after, () => _set(true));
  }

  @override
  Widget build(BuildContext context) {
    if (!_computer) return widget.child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _input(),
      onPointerHover: (_) => _input(),
      onPointerSignal: (_) => _input(),
      child: widget.child,
    );
  }
}
