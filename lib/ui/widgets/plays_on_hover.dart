/// Lets what is under the pointer move even when motion is reduced, the
/// system's asking included: a pointer on a picture asks to see it play.
/// Not while the app is unfocused: a hidden window may never hear the
/// pointer leave.
library;

import 'package:flutter/widgets.dart';

import 'still_when_unfocused.dart';

/// Wrap it outside any tap layer stacked over the picture: a [Stack]
/// hit-tests only its topmost child, so a region beneath never hears the
/// pointer.
class PlaysOnHover extends StatefulWidget {
  const PlaysOnHover({super.key, required this.child});

  final Widget child;

  @override
  State<PlaysOnHover> createState() => _PlaysOnHoverState();
}

class _PlaysOnHoverState extends State<PlaysOnHover> {
  var _hovered = false;

  void _hover(bool hovered) {
    if (hovered != _hovered) setState(() => _hovered = hovered);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Unfocused, the pointer may leave unheard; a hover counts again once
    // the pointer moves.
    if (!StillWhenUnfocused.focusedOf(context)) _hovered = false;
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    // Hover reaches what lies behind too, such as a message's actions.
    opaque: false,
    onEnter: (_) => _hover(true),
    onHover: (_) => _hover(true),
    onExit: (_) => _hover(false),
    // Always this MediaQuery, hovered or not: the picture keeps its state
    // and plays on from the frame it held.
    child: MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations:
            MediaQuery.disableAnimationsOf(context) &&
            !(_hovered && StillWhenUnfocused.focusedOf(context)),
      ),
      child: widget.child,
    ),
  );
}
