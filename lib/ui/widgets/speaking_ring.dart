/// The green ring round someone who is being heard.
library;

import 'package:flutter/material.dart';

import '../theme/loaf_theme.dart';

class SpeakingRing extends StatelessWidget {
  const SpeakingRing({
    super.key,
    required this.speaking,
    required this.child,
    this.radius,
    this.width = 2,
  });

  final bool speaking;
  final Widget child;

  /// Null rings a circle; otherwise a rounded square with this corner
  /// radius.
  final double? radius;
  final double width;

  @override
  Widget build(BuildContext context) {
    final radius = this.radius;
    return AnimatedContainer(
      duration: LoafMotion.fast,
      curve: LoafMotion.ease,
      // In front of the child rather than round it, so nothing moves.
      foregroundDecoration: BoxDecoration(
        shape: radius == null ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: radius == null ? null : BorderRadius.circular(radius),
        border: Border.all(
          color: speaking ? LoafTokens.of(context).online : Colors.transparent,
          width: width,
        ),
      ),
      child: child,
    );
  }
}
