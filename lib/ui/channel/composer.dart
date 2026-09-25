/// The message composer at the bottom of a channel. A mockup: typing and
/// sending do not append anything, but the send button's enabled state
/// really does track the text field.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../members/role_colors.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'message_actions.dart';
import 'timeline_controller.dart';

/// Every control in the composer row is this tall. Equal heights are what
/// make `CrossAxisAlignment.end` also read as vertically centred.
const _controlSize = 40.0;

/// Composer text metrics. The line box is centred in the control height by
/// arithmetic rather than by a calibrated nudge.
const _textSize = 15.0;
const _textHeight = 1.4;

/// Vertical padding that centres one line of text in the control height.
///
/// Worked out from the *scaled* line box, because iOS Text Size shrinks or
/// grows it: a constant pad only centres at the default size, and at the
/// smallest setting left the text sitting visibly below the buttons. Past the
/// point where a line no longer fits, the pad bottoms out at zero and the
/// field simply stands taller than the controls.
double _fieldPad(TextScaler scaler) {
  final lineBox = scaler.scale(_textSize) * _textHeight;
  return ((_controlSize - lineBox) / 2).clamp(0.0, _controlSize / 2);
}

class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.channelName,
    this.timeline,
    this.prefix = '#',
  });

  final String channelName;

  /// What the placeholder puts before the name: `#` for a channel, `@` for
  /// a person, nothing for a group DM.
  final String prefix;

  /// Supplies the message being replied to or edited, if any.
  final TimelineController? timeline;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _hasText = false;
  ComposerTarget? _target;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
    });
    widget.timeline?.addListener(_onTimeline);
    _focus.onKeyEvent = _onKey;
  }

  /// Desktop keys: Enter sends, Shift+Enter falls through to the field as a
  /// newline, Escape backs out of a reply or edit. On a phone Return is a
  /// newline and the send button sends, so none of this applies.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!isDesktop || event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final enter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    // Enter that confirms an input-method composition is not a send.
    final composing = _controller.value.composing.isValid;
    if (enter && !composing && !HardwareKeyboard.instance.isShiftPressed) {
      _submit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _target != null) {
      widget.timeline?.clearTarget();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Sends, or saves an edit. An edit emptied out is a request to delete, so
  /// it asks — cancelling leaves you in the edit.
  Future<void> _submit() async {
    final timeline = widget.timeline;
    if (timeline == null) return;
    final text = _controller.text;
    final target = _target;

    if (target != null && target.mode == ComposerMode.edit) {
      if (text.trim().isNotEmpty) {
        // Clearing the target clears the field: see _onTimeline.
        timeline.saveEdit(target.message.id, text);
      } else if (await confirmDeleteMessage(context)) {
        timeline.delete(target.message.id);
      }
      return;
    }

    if (text.trim().isEmpty) return;
    timeline.send(text);
    _controller.clear();
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timeline != widget.timeline) {
      oldWidget.timeline?.removeListener(_onTimeline);
      widget.timeline?.addListener(_onTimeline);
    }
  }

  /// Follows the timeline's target: editing loads the message into the field,
  /// and leaving an edit clears it again rather than stranding the old text.
  /// Either way the field takes focus, since typing is the next thing you do.
  void _onTimeline() {
    final next = widget.timeline?.target;
    if (identical(next, _target)) return;
    final wasEditing = _target?.mode == ComposerMode.edit;
    setState(() => _target = next);

    if (next?.mode == ComposerMode.edit) {
      _controller.text = next!.message.body;
    } else if (wasEditing) {
      _controller.clear();
    }
    if (next != null) _focus.requestFocus();
  }

  @override
  void dispose() {
    widget.timeline?.removeListener(_onTimeline);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final target = _target;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (target != null)
          _TargetChip(
            target: target,
            onCancel: () => widget.timeline?.clearTarget(),
          ),
        _field(tokens, hasTarget: target != null),
      ],
    );
  }

  Widget _field(LoafTokens tokens, {required bool hasTarget}) {
    return Container(
      margin: EdgeInsets.fromLTRB(
        LoafSpace.x4,
        // The card already separates the field from the timeline.
        hasTarget ? LoafSpace.x2 : LoafSpace.x4,
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
            child: Padding(
              // Centres the line box in the control height. Arithmetic, not
              // calibration — see _fieldPad.
              padding: EdgeInsets.symmetric(
                vertical: _fieldPad(MediaQuery.textScalerOf(context)),
              ),
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                minLines: 1,
                maxLines: 5,
                // An explicit line height keeps the field's height
                // independent of whatever the theme's bodyLarge happens to be.
                style: loafBody(
                  _textSize,
                  400,
                  height: _textHeight,
                ).copyWith(color: tokens.textBody),
                decoration: InputDecoration(
                  // Collapsed so the field is exactly its line box and the
                  // padding above does the centring. Left to itself the
                  // decorator adds its own vertical padding, which is what
                  // pushed this text off the icons' centreline.
                  isCollapsed: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: 'Message ${widget.prefix}${widget.channelName}',
                  hintStyle: loafBody(
                    _textSize,
                    400,
                    height: _textHeight,
                  ).copyWith(color: tokens.textMuted),
                ),
              ),
            ),
          ),
          _IconAction(icon: LucideIcons.smile, onTap: () {}),
          _IconAction(icon: LucideIcons.paperclip, onTap: () {}),
          const SizedBox(width: LoafSpace.x1),
          // Enabled for an emptied edit too: sending that is how you ask to
          // delete the message.
          _SendButton(
            enabled: _hasText || _target?.mode == ComposerMode.edit,
            onTap: _submit,
          ),
        ],
      ),
    );
  }
}

/// What the composer is aimed at — "replying to Ada" or "editing message" —
/// as a raised card above the field, with a line of the message itself so
/// you can see what you are answering or changing. An accent bar marks it as
/// a mode you are in, not just a caption.
class _TargetChip extends StatelessWidget {
  const _TargetChip({required this.target, required this.onCancel});

  final ComposerTarget target;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final replying = target.mode == ComposerMode.reply;
    final author = target.message.author;

    final title = replying
        ? Row(
            children: [
              Text(
                'replying to ',
                style: loafBody(13, 500).copyWith(color: tokens.textBody),
              ),
              Flexible(
                child: Text(
                  author.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: loafBody(
                    13,
                    600,
                  ).copyWith(color: tokens.nameColor(author.role)),
                ),
              ),
            ],
          )
        : Text(
            'editing message',
            style: loafBody(13, 600).copyWith(color: tokens.textStrong),
          );

    return Container(
      key: const ValueKey('composer-target'),
      margin: const EdgeInsets.fromLTRB(
        LoafSpace.x4,
        LoafSpace.x2,
        LoafSpace.x4,
        0,
      ),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tokens.card,
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        border: Border.all(color: tokens.borderStrong),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, color: tokens.accent),
            const SizedBox(width: LoafSpace.x3),
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Icon(
                replying ? LucideIcons.reply : LucideIcons.pencil,
                size: 16,
                color: tokens.accent,
              ),
            ),
            const SizedBox(width: LoafSpace.x2),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: LoafSpace.x2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    title,
                    const SizedBox(height: 2),
                    Text(
                      target.message.body,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: loafBody(
                        13,
                        400,
                      ).copyWith(color: tokens.textMuted),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: replying ? 'Cancel reply' : 'Cancel edit',
              visualDensity: VisualDensity.compact,
              onPressed: onCancel,
              icon: Icon(LucideIcons.x, size: 16, color: tokens.textMuted),
            ),
          ],
        ),
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
