/// The message composer at the bottom of a channel. A mockup: typing and
/// sending do not append anything, but the send button's enabled state
/// really does track the text field.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/loaf_theme.dart';

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
      constraints: const BoxConstraints(minHeight: 46),
      decoration: BoxDecoration(
        color: tokens.card,
        borderRadius: BorderRadius.circular(LoafRadius.xxl),
        border: Border.all(color: tokens.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _IconAction(icon: LucideIcons.plus, onTap: () {}),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: LoafSpace.x2),
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 5,
                style: loafBody(15, 400).copyWith(color: tokens.textBody),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Message #${widget.channelName}',
                  hintStyle: loafBody(
                    15,
                    400,
                  ).copyWith(color: tokens.textMuted),
                ),
              ),
            ),
          ),
          _IconAction(icon: LucideIcons.smile, onTap: () {}),
          _IconAction(icon: LucideIcons.paperclip, onTap: () {}),
          const SizedBox(width: LoafSpace.x1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: LoafSpace.x1),
            child: _SendButton(enabled: _hasText, onTap: () {}),
          ),
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
        child: Padding(
          padding: const EdgeInsets.all(LoafSpace.x2),
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
            child: Icon(LucideIcons.send, size: 16, color: tokens.textOnAccent),
          ),
        ),
      ),
    );
  }
}
