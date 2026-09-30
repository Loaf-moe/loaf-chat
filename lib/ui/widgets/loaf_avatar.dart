/// The one avatar every person, room and space is drawn with: a label on a
/// colour. Callers own the label and the type; this owns the shape.
library;

import 'package:flutter/material.dart';

class LoafAvatar extends StatelessWidget {
  const LoafAvatar({
    super.key,
    required this.label,
    required this.color,
    required this.size,
    required this.textStyle,
    this.radius,
    this.boxShadow,
  });

  /// Already-computed initials, drawn as given.
  final String label;
  final Color color;
  final double size;
  final TextStyle textStyle;

  /// Null draws a circle; otherwise a rounded square with this corner radius.
  final double? radius;
  final List<BoxShadow>? boxShadow;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          shape: radius == null ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: radius == null ? null : BorderRadius.circular(radius!),
          boxShadow: boxShadow,
        ),
        child: Text(label, style: textStyle.copyWith(color: Colors.white)),
      ),
    );
  }
}
