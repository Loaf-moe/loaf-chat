/// The message composer at the bottom of a channel. A mockup: typing and
/// sending do not append anything, but the send button's enabled state
/// really does track the text field.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';

/// Every control in the composer row is this tall. Equal heights are what
/// make `CrossAxisAlignment.end` also read as vertically centred.
const _controlSize = 40.0;

class Composer extends StatefulWidget {
  const Composer({super.key, required this.channelName});

  final String channelName;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        LoafSpace.x4,
        LoafSpace.x4,
        LoafSpace.x4,
        LoafSpace.x3,
      ),
      decoration: BoxDecoration(
        color: tokens.card,
        borderRadius: BorderRadius.circular(LoafRadius.xxl),
        border: Border.all(color: tokens.border),
      ),
      // Every control is exactly [_controlSize] tall, so bottom-aligning them
      // also lines up their centres. The 3px band above and below makes the
      // single-line composer 46 tall without a minHeight that would strand
      // the controls at the bottom of an over-tall row.
      padding: const EdgeInsets.symmetric(
        horizontal: LoafSpace.x2,
        vertical: 3,
      ),
      child: Row(
        // End, not centre: as the field grows to five lines the buttons stay
        // beside the last line rather than floating to the middle.
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _IconAction(icon: LucideIcons.plus, onTap: () {}),
          Expanded(
            child: TextField(
              controller: _controller,
              minLines: 1,
              maxLines: 5,
              // An explicit line height keeps the field's height independent
              // of whatever the theme's bodyLarge happens to be.
              style: loafBody(
                15,
                400,
                height: 1.4,
              ).copyWith(color: tokens.textBody),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                // Asymmetric on purpose. Outfit's glyphs paint lower inside
                // their line box than its declared metrics predict, so
                // symmetric padding leaves the text visibly below the icons
                // even though the boxes are centred. The 4px difference is
                // measured off the rendered pixels, not derived.
                // ponytail: calibrated for Outfit at 15px; re-measure if the
                // UI face or composer text size changes.
                contentPadding: const EdgeInsets.only(top: 6, bottom: 14),
                hintText: 'Message #${widget.channelName}',
                hintStyle: loafBody(
                  15,
                  400,
                  height: 1.4,
                ).copyWith(color: tokens.textMuted),
              ),
            ),
          ),
          _IconAction(icon: LucideIcons.smile, onTap: () {}),
          _IconAction(icon: LucideIcons.paperclip, onTap: () {}),
          const SizedBox(width: LoafSpace.x1),
          _SendButton(enabled: _hasText, onTap: () {}),
        ],
      ),
    );
  }
}

/// An icon button that scales down slightly on press, per the design
/// system's press motion.
class _IconAction extends StatefulWidget {
  const _IconAction({required this.icon, this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? LoafMotion.iconPressScale : 1.0,
        duration: LoafMotion.fast,
        curve: LoafMotion.ease,
        child: SizedBox(
          width: _controlSize,
          height: _controlSize,
          child: Icon(widget.icon, size: 20, color: tokens.textMuted),
        ),
      ),
    );
  }
}

class _SendButton extends StatefulWidget {
  const _SendButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return GestureDetector(
      onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
      onTapUp: widget.enabled ? (_) => _setPressed(false) : null,
      onTapCancel: widget.enabled ? () => _setPressed(false) : null,
      onTap: widget.enabled ? widget.onTap : null,
      child: SizedBox(
        width: _controlSize,
        height: _controlSize,
        child: Center(
          child: AnimatedScale(
            scale: _pressed ? LoafMotion.iconPressScale : 1.0,
            duration: LoafMotion.fast,
            curve: LoafMotion.ease,
            child: AnimatedOpacity(
              opacity: widget.enabled ? 1.0 : 0.4,
              duration: LoafMotion.normal,
              curve: LoafMotion.ease,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: tokens.accent,
                  shape: BoxShape.circle,
                  boxShadow: widget.enabled ? tokens.shadowAccent : null,
                ),
                child: Icon(
                  LucideIcons.send,
                  size: 16,
                  color: tokens.textOnAccent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
