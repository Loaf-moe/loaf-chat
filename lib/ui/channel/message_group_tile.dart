/// Renders one [MessageGroup]: one avatar and header, then each message in
/// the run.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../members/role_colors.dart';
import '../mock/fixtures.dart';
import '../model/media_source.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/loaf_avatar.dart';
import 'media_open.dart';
import 'media_row.dart';
import 'message_actions.dart';
import 'message_markup.dart';
import 'message_text.dart';
import 'timeline.dart';

String _formatTime(DateTime time) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}';
}

/// A message jumped to: [key] goes on its row so the timeline can bring
/// it into view, and while [lit] it glows.
typedef JumpFocus = ({String id, GlobalKey key, bool lit});

class MessageGroupTile extends StatelessWidget {
  const MessageGroupTile({
    super.key,
    required this.group,
    this.controller,
    this.focus,
  });

  final MessageGroup group;

  /// When set, each message offers its actions: long press on a phone,
  /// hover and right-click on a computer. Left null, the tile is
  /// display-only.
  final Timeline? controller;

  /// The message in this group that was jumped to, if any.
  final JumpFocus? focus;

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
    final Widget row;
    // A locked message has nothing in it to copy, reply to or react to.
    if (controller == null || message.locked) {
      // Where this device can write, it is verified: the key never came.
      row = _MessageBody(
        key: ValueKey(message.id),
        message: message,
        keyNeverCame: controller?.writable ?? false,
        you: controller?.you.id,
      );
    } else {
      // Keyed, so a message keeps its own State (a video playing in it)
      // when the list around it changes.
      row = isDesktop
          ? _PointerMessage(
              key: ValueKey(message.id),
              message: message,
              controller: controller,
            )
          : _TouchMessage(
              key: ValueKey(message.id),
              message: message,
              controller: controller,
            );
    }
    final focus = this.focus;
    final focused = focus != null && focus.id == message.id;
    // Wrapped whether focused or not: a row that gains a wrapper is
    // reparented and loses its State (a video playing in it) as it is lit.
    return _JumpGlow(
      focusKey: focused ? focus.key : null,
      lit: focused && focus.lit,
      child: row,
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    return LoafAvatar(
      label: member.initials,
      color: member.color,
      size: 36,
      image: member.avatar,
      textStyle: loafBody(13, 600),
    );
  }
}

class _MessageBody extends StatelessWidget {
  const _MessageBody({
    super.key,
    required this.message,
    this.onSelectionChanged,
    this.onReact,
    this.onAddReaction,
    this.onRetry,
    this.onDiscard,
    this.keyNeverCame = false,
    this.you,
    this.onOpenReply,
  });

  final Message message;

  /// Tapping the quote of what this replies to goes there. Null leaves the
  /// quote display-only.
  final VoidCallback? onOpenReply;

  /// Your user id, so mentions of you stand out.
  final String? you;

  /// Locked on a verified device: no key for it reached this one.
  final bool keyNeverCame;

  /// A failed message's two ways forward: send it again, or give up on it.
  final VoidCallback? onRetry;
  final VoidCallback? onDiscard;

  /// Tapping a reaction pill toggles your own on it: join the 🔥 or take
  /// yours back. Null leaves the pills display-only.
  final ValueChanged<String>? onReact;

  /// The trailing + pill: opens the message's actions, reactions first.
  /// Receives where it was tapped, for a menu to open at. Null draws no +
  /// pill, since there would be nothing behind it.
  final ValueChanged<Offset>? onAddReaction;

  /// When set, the text is selectable and this hears the selected text.
  /// Desktop only: on a phone, selection would swallow the long press.
  final ValueChanged<String>? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    if (message.locked) {
      return Text(
        keyNeverCame
            ? 'encrypted · the key for this never reached this device'
            : 'encrypted · readable once this device is verified',
        style: loafBody(
          15,
          400,
          height: 1.5,
        ).copyWith(color: tokens.textMuted, fontStyle: FontStyle.italic),
      );
    }
    final replyTo = message.replyTo;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (replyTo != null)
          _ReplyContext(replyTo: replyTo, onTap: onOpenReply),
        if (message.media != null)
          MediaRow(
            key: ValueKey(message.id),
            media: message.media!,
            uploaded: message.uploaded,
            // Only what the server has can be fetched whole. Where there
            // is a player, the row plays a video in place instead.
            onOpen: message.status == MessageStatus.sent
                ? () => openMedia(context, message.media!)
                : null,
            onRetry: () =>
                MediaSourceScope.of(context).retryPreview(message.media!),
          ),
        // Only media goes without words; a text message always draws its text.
        if (message.media == null || message.body.isNotEmpty) ...[
          if (message.media != null) const SizedBox(height: LoafSpace.x2),
          _text(tokens),
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
    return switch (message.status) {
      MessageStatus.sent => body,
      // Dimmed until the server has it: it is on its way, not there yet.
      MessageStatus.sending => Opacity(opacity: 0.5, child: body),
      MessageStatus.failed => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Opacity(opacity: 0.5, child: body),
          _FailedLine(onRetry: onRetry, onDiscard: onDiscard),
        ],
      ),
    };
  }

  Widget _text(LoafTokens tokens) {
    final text = MessageText(
      blocks: parseMessage(formatted: message.formatted, body: message.body),
      style: loafBody(15, 400, height: 1.5).copyWith(color: tokens.textBody),
      you: you,
      trailing: message.edited
          ? TextSpan(
              text: ' (edited)',
              style: loafBody(11, 400).copyWith(color: tokens.textMuted),
            )
          : null,
    );
    final onSelectionChanged = this.onSelectionChanged;
    if (onSelectionChanged == null) return text;
    // One selection across every paragraph, quote and code block, as a
    // browser gives; links inside it still open on a click.
    return SelectionArea(
      // The message's own right-click menu replaces the stock one; it offers
      // Copy selection whenever there is something selected. An empty
      // builder rather than null, which SelectionArea does not survive.
      contextMenuBuilder: (_, _) => const SizedBox.shrink(),
      onSelectionChanged: (content) =>
          onSelectionChanged(content?.plainText ?? ''),
      child: text,
    );
  }
}

class _ReplyContext extends StatelessWidget {
  const _ReplyContext({required this.replyTo, this.onTap});

  final Message replyTo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final quote = Padding(
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
                      text: replyTo.stub
                          ? '  a message further up'
                          : replyTo.locked
                          ? '  an encrypted message'
                          : replyTo.media != null
                          ? '  ${quoteOf(replyTo)}'
                          : '  ${plainTextOf(parseMessage(formatted: replyTo.formatted, body: replyTo.body))}',
                      style: loafBody(11, 400).copyWith(
                        color: tokens.textMuted,
                        fontStyle: replyTo.stub || replyTo.locked
                            ? FontStyle.italic
                            : null,
                      ),
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
    final onTap = this.onTap;
    if (onTap == null) return quote;
    // The quote is a way to what it answers: a pointer says so.
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: quote,
      ),
    );
  }
}

/// Under a message that did not send: say so, and offer both ways on.
class _FailedLine extends StatelessWidget {
  const _FailedLine({required this.onRetry, required this.onDiscard});

  final VoidCallback? onRetry;
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final quiet = loafBody(11, 400).copyWith(color: tokens.textMuted);
    Widget action(String label, VoidCallback? onTap) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(LoafRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x1),
        child: Text(
          label,
          style: loafBody(11, 600).copyWith(color: tokens.accent),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: LoafSpace.x1),
      child: Row(
        children: [
          Icon(LucideIcons.circleAlert, size: 12, color: tokens.accent),
          const SizedBox(width: LoafSpace.x1),
          Text("didn't send", style: quiet),
          Text(' · ', style: quiet),
          action('retry', onRetry),
          Text(' · ', style: quiet),
          action('discard', onDiscard),
        ],
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
        if (onAdd case final onAdd?)
          GestureDetector(
            onTapUp: (d) => onAdd(d.globalPosition),
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
  const _TouchMessage({
    super.key,
    required this.message,
    required this.controller,
  });

  final Message message;
  final Timeline controller;

  @override
  State<_TouchMessage> createState() => _TouchMessageState();
}

class _TouchMessageState extends State<_TouchMessage> {
  /// Held while the sheet is up, so you can see which message you are
  /// acting on.
  bool _active = false;

  bool get _canReact =>
      canReactTo(widget.message, writable: widget.controller.writable);

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
        you: widget.controller.you.id,
        onReact: _canReact
            ? (emoji) =>
                  widget.controller.toggleReaction(widget.message.id, emoji)
            : null,
        onAddReaction: _canReact ? (_) => _openSheet() : null,
        onRetry: () => widget.controller.retry(widget.message.id),
        onDiscard: () => widget.controller.discard(widget.message.id),
        onOpenReply: widget.message.replyTo == null
            ? null
            : () => widget.controller.jumpTo(widget.message.replyTo!.id),
      ),
    ),
  );
}

/// Desktop: text stays selectable, hovering shows a toolbar on the message's
/// top edge, and right-click opens the action menu — leading with Copy
/// selection when there is one.
class _PointerMessage extends StatefulWidget {
  const _PointerMessage({
    super.key,
    required this.message,
    required this.controller,
  });

  final Message message;
  final Timeline controller;

  @override
  State<_PointerMessage> createState() => _PointerMessageState();
}

class _PointerMessageState extends State<_PointerMessage> {
  final _link = LayerLink();
  final _toolbar = OverlayPortalController();

  // A file's menu names the app it opens in; ask early, so the answer is
  // here before any right-click.
  @override
  void initState() {
    super.initState();
    final media = widget.message.media;
    if (media != null) lookUpDefaultApp(media);
  }

  @override
  void didUpdateWidget(_PointerMessage old) {
    super.didUpdateWidget(old);
    final media = widget.message.media;
    if (media != null && media.name != old.message.media?.name) {
      lookUpDefaultApp(media);
    }
  }

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

  bool get _canReact =>
      canReactTo(widget.message, writable: widget.controller.writable);

  void _setHover({bool? message, bool? toolbar}) {
    setState(() {
      _overMessage = message ?? _overMessage;
      _overToolbar = toolbar ?? _overToolbar;
    });
    // The toolbar reacts and replies, which wait until the server has the
    // message and need a timeline that can be written to; right-click still
    // copies it.
    if ((_overMessage || _overToolbar) && _canReact) {
      _toolbar.show();
    } else {
      _toolbar.hide();
    }
  }

  Future<void> _openMenu(Offset globalPosition, {String selection = ''}) async {
    // Hiding the toolbar unmounts its MouseRegion, which never reports the
    // pointer leaving; forget it here or the toolbar and wash stay stuck on.
    setState(() {
      _active = true;
      _overToolbar = false;
    });
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
      // The Align only loosens the overlay's constraints so the follower
      // shrinks to the toolbar; inside the follower it would fill the window,
      // and `followerAnchor` would place the window's edge, not the toolbar's.
      overlayChildBuilder: (context) => Align(
        alignment: Alignment.topLeft,
        child: CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.centerRight,
          offset: const Offset(-LoafSpace.x2, 0),
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
      // The full row, not just the text: the toolbar sits at the row's right
      // end, where it never covers a short message, and the wash and hover
      // span the row like the rest of the app's list rows.
      child: CompositedTransformTarget(
        link: _link,
        child: SizedBox(
          width: double.infinity,
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
                  you: widget.controller.you.id,
                  onReact: _canReact
                      ? (emoji) => widget.controller.toggleReaction(
                          widget.message.id,
                          emoji,
                        )
                      : null,
                  onAddReaction: _canReact ? _openMenu : null,
                  onSelectionChanged: (text) => _selection = text,
                  onRetry: () => widget.controller.retry(widget.message.id),
                  onDiscard: () => widget.controller.discard(widget.message.id),
                  onOpenReply: widget.message.replyTo == null
                      ? null
                      : () => widget.controller.jumpTo(
                          widget.message.replyTo!.id,
                        ),
                ),
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

/// How long the glow takes to fade once the message has been seen.
const _glowFade = Duration(milliseconds: 600);

/// The accent wash behind a message jumped to, so the eye finds where it
/// landed. Unlike [_Highlight] it is the accent, not the card: it marks a
/// place rather than a pointer. Only the focused row ([focusKey] set) draws
/// the wash; the rest wrap their row all the same, to keep it where it is
/// in the tree.
class _JumpGlow extends StatelessWidget {
  const _JumpGlow({
    required this.focusKey,
    required this.lit,
    required this.child,
  });

  final GlobalKey? focusKey;
  final bool lit;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (focusKey != null)
          Positioned(
            key: focusKey,
            left: -LoafSpace.x2,
            right: -LoafSpace.x2,
            top: -2,
            bottom: -2,
            child: AnimatedContainer(
              key: const ValueKey('jump-glow'),
              duration: _glowFade,
              curve: LoafMotion.ease,
              decoration: BoxDecoration(
                color: tokens.accent.withValues(alpha: lit ? 0.18 : 0),
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
