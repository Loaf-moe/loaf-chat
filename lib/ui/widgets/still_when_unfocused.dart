/// Asks for reduced motion below it while the app is not focused: every
/// frame redraws the whole window, and on X11 copies it through the CPU, so
/// loops rest unless the app has focus.
library;

import 'package:flutter/widgets.dart';

/// Sits in `MaterialApp.builder`, below the MediaQuery that carries the
/// reduce motion setting, so [preferStillOf] sees that setting.
class StillWhenUnfocused extends StatefulWidget {
  const StillWhenUnfocused({super.key, required this.child});

  final Widget child;

  /// Whether the app has focus; with no [StillWhenUnfocused] above, it does.
  static bool focusedOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Motion>()?.focused ?? true;

  /// Whether less motion is asked for by preference, focus left out. A
  /// preference counts only if it is in the MediaQuery above this widget.
  static bool preferStillOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Motion>()?.preferStill ??
      MediaQuery.disableAnimationsOf(context);

  @override
  State<StillWhenUnfocused> createState() => _StillWhenUnfocusedState();
}

class _StillWhenUnfocusedState extends State<StillWhenUnfocused>
    with WidgetsBindingObserver {
  // Before the platform has said anything, the app is taken as focused.
  late var _focused = switch (WidgetsBinding.instance.lifecycleState) {
    null || AppLifecycleState.resumed => true,
    _ => false,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final focused = state == AppLifecycleState.resumed;
    if (focused != _focused) setState(() => _focused = focused);
  }

  @override
  Widget build(BuildContext context) {
    final preferStill = MediaQuery.disableAnimationsOf(context);
    return _Motion(
      focused: _focused,
      preferStill: preferStill,
      child: MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(disableAnimations: preferStill || !_focused),
        child: widget.child,
      ),
    );
  }
}

class _Motion extends InheritedWidget {
  const _Motion({
    required this.focused,
    required this.preferStill,
    required super.child,
  });

  final bool focused;
  final bool preferStill;

  @override
  bool updateShouldNotify(_Motion old) =>
      old.focused != focused || old.preferStill != preferStill;
}
