/// The one button widget for the app. Three emphases share one shape —
/// mixing real buttons with bare text links reads as inconsistency rather
/// than as hierarchy — and two sizes: small pills that hug their label
/// (banner actions), and large pills that stretch to fill their parent
/// (the login screen's primary action).
library;

import 'package:flutter/material.dart';

import '../theme/loaf_theme.dart';

enum LoafButtonEmphasis { filled, outlined, quiet }

enum LoafButtonSize { small, large }

class LoafButton extends StatefulWidget {
  const LoafButton({
    super.key,
    required this.label,
    required this.onTap,
    this.emphasis = LoafButtonEmphasis.filled,
    this.size = LoafButtonSize.large,
    this.icon,
    this.leading,
  });

  final String label;

  /// Null renders the button disabled: dimmed, and unresponsive to taps.
  final VoidCallback? onTap;
  final LoafButtonEmphasis emphasis;
  final LoafButtonSize size;
  final IconData? icon;

  /// Drawn where [icon] would be, for marks that are not icons (an identity
  /// provider's initial). Takes precedence over [icon].
  final Widget? leading;

  @override
  State<LoafButton> createState() => _LoafButtonState();
}

class _LoafButtonState extends State<LoafButton> {
  bool _pressed = false;

  void _setPressed(bool value) =>
      _pressed == value ? null : setState(() => _pressed = value);

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final enabled = widget.onTap != null;
    final large = widget.size == LoafButtonSize.large;

    final Color background;
    final Color labelColor;
    final Border? border;
    final List<BoxShadow>? shadow;
    switch (widget.emphasis) {
      case LoafButtonEmphasis.filled:
        background = tokens.accent;
        labelColor = tokens.textOnAccent;
        border = null;
        shadow = _pressed ? null : tokens.shadowAccent;
      case LoafButtonEmphasis.outlined:
        background = Colors.transparent;
        labelColor = tokens.textStrong;
        border = Border.all(color: tokens.borderStrong);
        shadow = null;
      case LoafButtonEmphasis.quiet:
        background = Colors.transparent;
        labelColor = tokens.textBody;
        border = null;
        shadow = null;
    }

    final label = Text(
      widget.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: loafBody(large ? 15 : 13, 600).copyWith(color: labelColor),
    );

    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        child: AnimatedScale(
          scale: _pressed ? LoafMotion.pressScale : 1.0,
          duration: LoafMotion.fast,
          curve: LoafMotion.ease,
          child: Container(
            height: large ? 48 : 30,
            padding: EdgeInsets.symmetric(
              horizontal: large ? LoafSpace.x5 : LoafSpace.x4,
            ),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(LoafRadius.full),
              border: border,
              boxShadow: shadow,
            ),
            // A hugging button (small pills in a Row that sizes to its
            // content) gets an unbounded main axis here, so Flexible would
            // assert; a stretched button (the large primary action) gets a
            // bounded one, so Flexible is what lets the label ellipsise
            // instead of overflowing. LayoutBuilder picks the right one for
            // whichever context this button ends up in.
            child: LayoutBuilder(
              builder: (context, constraints) => Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.leading != null) ...[
                    widget.leading!,
                    const SizedBox(width: LoafSpace.x2),
                  ] else if (widget.icon != null) ...[
                    Icon(widget.icon, size: 18, color: labelColor),
                    const SizedBox(width: LoafSpace.x2),
                  ],
                  constraints.maxWidth.isFinite
                      ? Flexible(child: label)
                      : label,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
