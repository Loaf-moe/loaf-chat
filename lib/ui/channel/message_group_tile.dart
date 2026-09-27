/// Renders one [MessageGroup]: one avatar and header, then each message in
/// the run.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../members/role_colors.dart';
import '../mock/fixtures.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'message_actions.dart';
import 'timeline.dart';

String _formatTime(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}';
}

class MessageGroupTile extends StatelessWidget {
  const MessageGroupTile({super.key, required this.group, this.controller});

  final MessageGroup group;

  /// When set, each message offers its actions: long press on a phone,
  /// hover and right-click on a computer. Left null, the tile is
  /// display-only.
  final Timeline? controller;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final author = group.author;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Avatar(member: author),
        const SizedBox(width: LoafSpace.x3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    author.name,
                    style: loafBody(
                      15,
                      600,
                    ).copyWith(color: tokens.nameColor(author.role)),
                  ),
                  const SizedBox(width: LoafSpace.x2),
                  Text(
                    _formatTime(group.sentAt),
                    style: loafBody(11, 400).copyWith(color: tokens.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: LoafSpace.x1),
              for (var i = 0; i < group.messages.length; i++) ...[
                if (i > 0) const SizedBox(height: 2),
                _interactive(group.messages[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _interactive(Message message) {
    final controller = this.controller;
    if (controller == null) return _MessageBody(message: message);
    return isDesktop
        ? _PointerMessage(message: message, controller: controller)
        : _TouchMessage(message: message, controller: controller);
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 18,
      backgroundColor: member.color,
      child: Text(
        member.initials,
        style: loafBody(13, 600).copyWith(color: Colors.white),
      ),
    );
  }
}

class _MessageBody extends StatelessWidget {
  const _MessageBody({
    required this.message,
    this.onSelectionChanged,
    this.onReact,
    this.onAddReaction,
  });

  final Message message;

  /// Tapping a reaction pill toggles your own on it: join the 🔥 or take
  /// yours back. Null leaves the pills display-only.
  final ValueChanged<String>? onReact;

  /// The trailing + pill: opens the message's actions, reactions first.
  /// Receives where it was tapped, for a menu to open at.
  final ValueChanged<Offset>? onAddReaction;

  /// When set, the text is selectable and this hears the selected text.
  /// Desktop only: on a phone, selection would swallow the long press.
  final ValueChanged<String>? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final replyTo = message.replyTo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (replyTo != null) _ReplyContext(replyTo: replyTo),
        _text(tokens),
        if (message.imageAspect != null) ...[
          const SizedBox(height: LoafSpace.x2),
          _ImagePlaceholder(aspect: message.imageAspect!),
        ],
        if (message.reactions.isNotEmpty) ...[
          const SizedBox(height: LoafSpace.x2),
          _ReactionsWrap(
            reactions: message.reactions,
            onReact: onReact,
            onAdd: onAddReaction,
          ),
        ],
      ],
    );
  }

  Widget _text(LoafTokens tokens) {
    final span = TextSpan(
      style: loafBody(15, 400, height: 1.5).copyWith(color: tokens.textBody),
      children: [
        TextSpan(text: message.body),
        if (message.edited)
          TextSpan(
            text: ' (edited)',
            style: loafBody(11, 400).copyWith(color: tokens.textMuted),
          ),
      ],
    );
    final onSelectionChanged = this.onSelectionChanged;
    if (onSelectionChanged == null) return Text.rich(span);
    final plain = span.toPlainText();
    return SelectableText.rich(
      span,
      // The message's own right-click menu replaces the stock one; it offers
      // Copy selection whenever there is something selected.
      contextMenuBuilder: null,
      onSelectionChanged: (selection, _) =>
          onSelectionChanged(selection.textInside(plain)),
    );
  }
}

class _ReplyContext extends StatelessWidget {
  const _ReplyContext({required this.replyTo});

  final Message replyTo;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: LoafSpace.x1),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 2,
              margin: const EdgeInsets.only(right: LoafSpace.x2),
              decoration: BoxDecoration(
                color: tokens.border,
                borderRadius: BorderRadius.circular(LoafRadius.sm),
              ),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: replyTo.author.name,
                      style: loafBody(
                        11,
                        600,
                      ).copyWith(color: tokens.nameColor(replyTo.author.role)),
                    ),
                    TextSpan(
                      text: '  ${replyTo.body}',
                      style: loafBody(
                        11,
                        400,
                      ).copyWith(color: tokens.textMuted),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({required this.aspect});

  final double aspect;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: AspectRatio(
          aspectRatio: aspect,
          child: Container(
            decoration: BoxDecoration(
              color: tokens.sunken,
              border: Border.all(color: tokens.border),
              borderRadius: BorderRadius.circular(LoafRadius.lg),
            ),
            child: Icon(LucideIcons.image, color: tokens.textMuted),
          ),
        ),
      ),
    );
  }
}

class _ReactionsWrap extends StatelessWidget {
  const _ReactionsWrap({required this.reactions, this.onReact, this.onAdd});

  final List<Reaction> reactions;
  final ValueChanged<String>? onReact;
  final ValueChanged<Offset>? onAdd;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Wrap(
      spacing: LoafSpace.x2,
      runSpacing: LoafSpace.x2,
      children: [
        for (final reaction in reactions)
          GestureDetector(
            onTap: onReact == null ? null : () => onReact!(reaction.emoji),
            child: Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x2),
              decoration: BoxDecoration(
                color: reaction.mine ? tokens.accentSoft : tokens.card,
                borderRadius: BorderRadius.circular(LoafRadius.full),
                border: Border.all(
                  color: reaction.mine ? tokens.accent : tokens.border,
                ),
              ),
              // A Container with `alignment` and no width expands to the
              // parent's max width, which makes every pill full-bleed and
              // forces one per line. A min-size Row hugs the text instead.
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${reaction.emoji} ${reaction.count}',
                    style: loafBody(11, 600).copyWith(color: tokens.textBody),
                  ),
                ],
              ),
            ),
          ),
        GestureDetector(
          onTapUp: onAdd == null ? null : (d) => onAdd!(d.globalPosition),
          child: Container(
            height: 26,
            width: 26,
            decoration: BoxDecoration(
              color: tokens.card,
              borderRadius: BorderRadius.circular(LoafRadius.full),
              border: Border.all(color: tokens.border),
            ),
            alignment: Alignment.center,
            child: Icon(
              LucideIcons.smilePlus,
              size: 14,
              color: tokens.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}

/// Mobile: long press, with a haptic, opens the action sheet. Nothing else —
/// no hover, no selection to compete with the press.
class _TouchMessage extends StatefulWidget {
  const _TouchMessage({required this.message, required this.controller});

  final Message message;
  final Timeline controller;

  @override
  State<_TouchMessage> createState() => _TouchMessageState();
}

class _TouchMessageState extends State<_TouchMessage> {
  /// Held while the sheet is up, so you can see which message you are
  /// acting on.
  bool _active = false;

  Future<void> _openSheet() async {
    HapticFeedback.mediumImpact();
    setState(() => _active = true);
    await showMessageActionsSheet(context, widget.controller, widget.message);
    if (mounted) setState(() => _active = false);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onLongPress: _openSheet,
    child: _Highlight(
      on: _active,
      child: _MessageBody(
        message: widget.message,
        onReact: (emoji) =>
            widget.controller.toggleReaction(widget.message.id, emoji),
        onAddReaction: (_) => _openSheet(),
      ),
    ),
  );
}

/// Desktop: text stays selectable, hovering shows a toolbar on the message's
/// top edge, and right-click opens the action menu — leading with Copy
/// selection when there is one.
class _PointerMessage extends StatefulWidget {
  const _PointerMessage({required this.message, required this.controller});

  final Message message;
  final Timeline controller;

  @override
  State<_PointerMessage> createState() => _PointerMessageState();
}

class _PointerMessageState extends State<_PointerMessage> {
  final _link = LayerLink();
  final _toolbar = OverlayPortalController();

  // The toolbar lives in the overlay, so the pointer can leave the message
  // for the toolbar without the toolbar vanishing out from under it.
  bool _overMessage = false;
  bool _overToolbar = false;
  bool _active = false;

  String _selection = '';

  /// The selection as it stood when the right button went down. Read then
  /// rather than on release, because the text field may move the selection
  /// in response to the same click.
  String? _selectionAtRightClick;

  void _setHover({bool? message, bool? toolbar}) {
    setState(() {
      _overMessage = message ?? _overMessage;
      _overToolbar = toolbar ?? _overToolbar;
    });
    if (_overMessage || _overToolbar) {
      _toolbar.show();
    } else {
      _toolbar.hide();
    }
  }

  Future<void> _openMenu(Offset globalPosition, {String selection = ''}) async {
    setState(() => _active = true);
    _toolbar.hide();
    await showMessageContextMenu(
      context,
      widget.controller,
      widget.message,
      globalPosition,
      selection: selection,
    );
    if (mounted) setState(() => _active = false);
  }

  // A raw Listener rather than a gesture recogniser: the selectable text
  // underneath claims secondary taps in the gesture arena, and the menu has
  // to open regardless.
  void _onPointerDown(PointerDownEvent event) {
    if (event.buttons & kSecondaryMouseButton != 0) {
      _selectionAtRightClick = _selection;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    final selection = _selectionAtRightClick;
    if (selection == null) return;
    _selectionAtRightClick = null;
    _openMenu(event.position, selection: selection);
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _toolbar,
      overlayChildBuilder: (context) => CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.topRight,
        followerAnchor: Alignment.centerRight,
        offset: const Offset(-LoafSpace.x2, 0),
        child: Align(
          alignment: Alignment.topLeft,
          child: MouseRegion(
            onEnter: (_) => _setHover(toolbar: true),
            onExit: (_) => _setHover(toolbar: false),
            child: _HoverToolbar(
              onReact: (emoji) =>
                  widget.controller.toggleReaction(widget.message.id, emoji),
              onReply: () => widget.controller.startReply(widget.message),
              onMore: _openMenu,
            ),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          onEnter: (_) => _setHover(message: true),
          onExit: (_) => _setHover(message: false),
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerUp: _onPointerUp,
            child: _Highlight(
              on: _active || _overMessage || _overToolbar,
              child: _MessageBody(
                message: widget.message,
                onReact: (emoji) =>
                    widget.controller.toggleReaction(widget.message.id, emoji),
                onAddReaction: _openMenu,
                onSelectionChanged: (text) => _selection = text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A soft card-coloured wash behind a message. It bleeds a little past the
/// body so it frames the text instead of touching it.
class _Highlight extends StatelessWidget {
  const _Highlight({required this.on, required this.child});

  final bool on;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: -LoafSpace.x2,
          right: -LoafSpace.x2,
          top: -2,
          bottom: -2,
          child: AnimatedContainer(
            duration: LoafMotion.fast,
            curve: LoafMotion.ease,
            decoration: BoxDecoration(
              color: tokens.card.withValues(alpha: on ? 0.6 : 0),
              borderRadius: BorderRadius.circular(LoafRadius.md),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _HoverToolbar extends StatelessWidget {
  const _HoverToolbar({
    required this.onReact,
    required this.onReply,
    required this.onMore,
  });

  final ValueChanged<String> onReact;
  final VoidCallback onReply;
  final ValueChanged<Offset> onMore;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);

    Widget button({
      required String tip,
      required Widget child,
      required GestureTapUpCallback onTapUp,
    }) => Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkResponse(
        radius: 16,
        onTapUp: onTapUp,
        onTap: () {},
        child: SizedBox(width: 32, height: 32, child: Center(child: child)),
      ),
    );

    return Material(
      color: tokens.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LoafRadius.md),
        side: BorderSide(color: tokens.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final emoji in quickReactions.take(3))
              button(
                tip: 'React $emoji',
                onTapUp: (_) => onReact(emoji),
                child: Text(emoji, style: const TextStyle(fontSize: 16)),
              ),
            button(
              tip: 'Reply',
              onTapUp: (_) => onReply(),
              child: Icon(LucideIcons.reply, size: 16, color: tokens.textMuted),
            ),
            button(
              tip: 'More',
              onTapUp: (details) => onMore(details.globalPosition),
              child: Icon(
                LucideIcons.ellipsis,
                size: 16,
                color: tokens.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
