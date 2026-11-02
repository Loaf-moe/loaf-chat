/// Asks for reduced motion below it while the app is not focused: every
/// frame redraws the whole window, and on X11 copies it through the CPU, so
/// loops rest unless the app has focus.
library;

import 'package:flutter/widgets.dart';

class StillWhenUnfocused extends StatefulWidget {
  const StillWhenUnfocused({super.key, required this.child});

  final Widget child;

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
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      disableAnimations: MediaQuery.disableAnimationsOf(context) || !_focused,
    ),
    child: widget.child,
  );
}
