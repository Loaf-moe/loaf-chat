/// The message composer at the bottom of a channel: text, emoji — picked, or
/// typed as `:shortcodes:` — `@person` and `#channel` mentions, and files
/// attached from the platform's own picker.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../members/role_colors.dart';
import '../model/models.dart';
import '../widgets/loaf_avatar.dart';
import '../widgets/toast.dart';
import 'attach.dart';
import 'media_row.dart';
import 'mentions.dart';
import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'message_actions.dart';
import 'sizes.dart';
import '../emoji/emoji_picker.dart';
import '../emoji/shortcodes.dart';
import 'timeline.dart';

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
    this.pickFiles = pickAttachments,
    this.people = const [],
    this.channels = const [],
  });

  final String channelName;

  /// What the placeholder puts before the name: `#` for a channel, `@` for
  /// a person, nothing for a group DM.
  final String prefix;

  /// Supplies the message being replied to or edited, if any.
  final Timeline? timeline;

  /// Asks for files to attach. The platform's own picker, but for tests.
  final AttachmentPicker pickFiles;

  /// Who `@` offers: the people here, in the member list's order. You are
  /// left out, since there is no telling yourself.
  final List<Member> people;

  /// What `#` offers: the channels around this one.
  final List<Channel> channels;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _hasText = false;
  ComposerTarget? _target;

  /// Emoji for the `:shortcode` being typed, or people or channels for the
  /// `@` or `#` mention, best first, and which one Enter or Tab would take.
  /// Empty when there is no popup.
  List<_Suggestion> _suggestions = const [];

  /// The [ShortcodeQuery] or [MentionQuery] being answered, and where it
  /// starts in the text.
  Object? _query;
  int? _queryStart;
  int _highlight = 0;

  /// Where the shortcode or mention Escape waved away starts. It stays
  /// away while that one is being typed, and comes back for the next.
  int? _dismissedAt;

  /// Mentions picked into the field. Sending keeps only those the text
  /// still holds.
  List<Mention> _picked = const [];

  final _fieldLink = LayerLink();
  final _suggestionsPortal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    // Coming back to a room still aimed at a reply or an edit: show it, since
    // that is what sending here would do.
    _target = widget.timeline?.target;
    if (_target case ComposerTarget(mode: ComposerMode.edit, :final message)) {
      _controller.text = message.body;
      _picked = mentionsOf(message);
      _hasText = message.body.trim().isNotEmpty;
    }
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
      _suggest();
    });
    _focus.addListener(_suggest);
    widget.timeline?.addListener(_onTimeline);
    _focus.onKeyEvent = _onKey;
  }

  /// Offers people or channels for the mention at the cursor, or emoji for
  /// the shortcode, if one is being typed into a focused field.
  void _suggest() {
    final value = _controller.value;
    final mention = _focus.hasFocus ? mentionAt(value) : null;
    final code = _focus.hasFocus && mention == null ? shortcodeAt(value) : null;
    final Object? query = mention ?? code;
    final start = mention?.start ?? code?.start;
    if (start != _dismissedAt) _dismissedAt = null;
    final List<_Suggestion> matches;
    if (start == null || start == _dismissedAt) {
      matches = const [];
    } else if (mention != null) {
      final found = searchMentions(mention.query, _candidates(mention.kind));
      matches = [for (final c in found) _MentionSuggestion(c)];
    } else {
      matches = [
        for (final m in shortcodes.search(code!.query, limit: 6))
          _EmojiSuggestion(m),
      ];
    }
    if (matches.isEmpty && _suggestions.isEmpty) return;
    setState(() {
      // A new letter narrows the list: start again from the best.
      if (query != _query) _highlight = 0;
      _query = query;
      _queryStart = start;
      _suggestions = matches;
    });
    matches.isEmpty ? _suggestionsPortal.hide() : _suggestionsPortal.show();
  }

  Iterable<MentionCandidate> _candidates(MentionKind kind) => switch (kind) {
    MentionKind.person => [
      for (final m in widget.people)
        if (m.id != widget.timeline?.you.id) MentionCandidate.person(m),
    ],
    MentionKind.channel => [
      for (final c in widget.channels) MentionCandidate.channel(c),
    ],
  };

  /// Puts [suggestion] where its shortcode or mention was being typed: an
  /// emoji in place of its code, a mention's name followed by a space, so
  /// the next word can simply be typed.
  void _acceptSuggestion(_Suggestion suggestion) {
    final start = _queryStart;
    if (start == null) return;
    final value = _controller.value;
    final end = value.selection.baseOffset;
    switch (suggestion) {
      case _EmojiSuggestion(:final match):
        final emoji = match.emoji.char;
        _controller.value = TextEditingValue(
          text: value.text.replaceRange(start, end, emoji),
          selection: TextSelection.collapsed(offset: start + emoji.length),
        );
      case _MentionSuggestion(:final candidate):
        final label = candidate.label;
        // A space already after the cursor is the one to step over.
        final spaced =
            end < value.text.length && value.text[end].trim().isEmpty;
        final text = value.text.replaceRange(
          start,
          end,
          spaced ? label : '$label ',
        );
        _picked = [..._picked, candidate.mention];
        _controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: start + label.length + 1),
        );
    }
  }

  /// Arrow keys move through the suggestions, Enter or Tab takes one, and
  /// Escape puts them away. On any platform with a keyboard: an iPad's
  /// works the same way.
  KeyEventResult _onSuggestionKey(KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final n = _suggestions.length;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight = (_highlight + 1) % n);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlight = (_highlight - 1 + n) % n);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        (key == LogicalKeyboardKey.tab &&
            !HardwareKeyboard.instance.isShiftPressed)) {
      _acceptSuggestion(_suggestions[_highlight]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _dismissedAt = _queryStart;
      _suggest();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Desktop keys: Enter sends, Shift+Enter falls through to the field as a
  /// newline, Escape backs out of a reply or edit. On a phone Return is a
  /// newline and the send button sends, so none of this applies. While
  /// emoji are being suggested, the keys work those first.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_suggestions.isNotEmpty) {
      final result = _onSuggestionKey(event);
      if (result == KeyEventResult.handled) return result;
    }
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
  /// Opens the emoji picker from [button] and puts the pick where the
  /// cursor was, replacing any selection — or at the end if the field was
  /// never focused.
  Future<void> _pickEmoji(BuildContext button) async {
    final box = button.findRenderObject()! as RenderBox;
    final emoji = await showEmojiPicker(
      context,
      anchor: box.localToGlobal(Offset.zero) & box.size,
    );
    if (emoji == null || !mounted) return;
    final value = _controller.value;
    final at = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    _controller.value = TextEditingValue(
      text: value.text.replaceRange(at.start, at.end, emoji),
      selection: TextSelection.collapsed(offset: at.start + emoji.length),
    );
  }

  /// Sends each picked file as its own message. A reply target goes with
  /// the first, as it would with text.
  Future<void> _attach() async {
    final timeline = widget.timeline;
    if (timeline == null) return;
    final picked = await widget.pickFiles(context);
    if (picked.isEmpty) return;
    final limit = await timeline.uploadLimit();
    for (final file in picked) {
      // Before reading it: a file the server will never take shouldn't
      // be loaded, or sit there failing.
      if (limit != null) {
        final int size;
        try {
          size = await file.length();
        } on Object {
          if (mounted) showToast(context, "couldn't read ${file.name}");
          continue;
        }
        if (size > limit) {
          if (mounted) showToast(context, tooBigToSend(file.name, size, limit));
          continue;
        }
      }
      final Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } on Object {
        if (mounted) showToast(context, "couldn't read ${file.name}");
        continue;
      }
      if (!mounted) return;
      timeline.sendFile(
        Attachment(name: file.name, bytes: bytes, mimeType: file.mimeType),
      );
    }
  }

  Future<void> _submit() async {
    final timeline = widget.timeline;
    if (timeline == null) return;
    // A complete :shortcode: goes as its emoji, whether or not it was
    // picked from the suggestions.
    final text = shortcodes.expand(_controller.text);
    final mentions = mentionsIn(text, _picked);
    final target = _target;

    if (target != null && target.mode == ComposerMode.edit) {
      if (text.trim().isNotEmpty) {
        // Clearing the target clears the field: see _onTimeline.
        timeline.saveEdit(target.message.id, text, mentions: mentions);
      } else if (await confirmDeleteMessage(context)) {
        timeline.delete(target.message.id);
      }
      return;
    }

    if (text.trim().isEmpty) return;
    timeline.send(text, mentions: mentions);
    _picked = const [];
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
      _picked = mentionsOf(next!.message);
      _controller.text = next.message.body;
    } else if (wasEditing) {
      _picked = const [];
      _controller.clear();
    }
    if (next != null) _focus.requestFocus();
  }

  @override
  void dispose() {
    widget.timeline?.removeListener(_onTimeline);
    _focus.removeListener(_suggest);
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
        _field(
          tokens,
          hasTarget: target != null,
          editing: target?.mode == ComposerMode.edit,
        ),
      ],
    );
  }

  Widget _field(
    LoafTokens tokens, {
    required bool hasTarget,
    required bool editing,
  }) {
    final field = Container(
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
          // An edit changes words only, so there is nothing to attach to it.
          if (!editing)
            _IconAction(
              icon: LucideIcons.plus,
              tooltip: 'Attach files',
              onTap: _attach,
            )
          else
            const SizedBox(width: LoafSpace.x2),
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
          Builder(
            builder: (button) => _IconAction(
              icon: LucideIcons.smile,
              tooltip: 'Emoji',
              onTap: () => _pickEmoji(button),
            ),
          ),
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
    return Padding(
      padding: EdgeInsets.fromLTRB(
        LoafSpace.x4,
        // The card already separates the field from the timeline.
        hasTarget ? LoafSpace.x2 : LoafSpace.x4,
        LoafSpace.x4,
        LoafSpace.x3,
      ),
      child: OverlayPortal(
        controller: _suggestionsPortal,
        // As in the hover toolbar, the Align only loosens the overlay's
        // constraints so the follower shrinks to the list.
        overlayChildBuilder: (context) => Align(
          alignment: Alignment.topLeft,
          child: CompositedTransformFollower(
            link: _fieldLink,
            targetAnchor: Alignment.topLeft,
            followerAnchor: Alignment.bottomLeft,
            offset: const Offset(0, -LoafSpace.x1),
            // Part of the field as far as taps go, so picking one keeps the
            // keyboard and focus where they are.
            child: TextFieldTapRegion(
              child: _Suggestions(
                matches: _suggestions,
                highlight: _highlight,
                onHover: (i) => setState(() => _highlight = i),
                onPick: _acceptSuggestion,
              ),
            ),
          ),
        ),
        child: CompositedTransformTarget(link: _fieldLink, child: field),
      ),
    );
  }
}

/// One row of the popup above the field.
sealed class _Suggestion {
  const _Suggestion();
}

class _EmojiSuggestion extends _Suggestion {
  const _EmojiSuggestion(this.match);
  final ShortcodeMatch match;
}

class _MentionSuggestion extends _Suggestion {
  const _MentionSuggestion(this.candidate);
  final MentionCandidate candidate;
}

/// What the `:shortcode` or `@`/`#` mention being typed could become, above
/// the field. An emoji row shows the code it matched under, so the next
/// time it can simply be typed; a person's shows their user id, which tells
/// two of the same name apart. Each row is a tap target too, which is how a
/// phone with no Tab key picks one.
class _Suggestions extends StatelessWidget {
  const _Suggestions({
    required this.matches,
    required this.highlight,
    required this.onHover,
    required this.onPick,
  });

  final List<_Suggestion> matches;
  final int highlight;
  final ValueChanged<int> onHover;
  final ValueChanged<_Suggestion> onPick;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    // A finger needs a taller row than a pointer.
    final rowHeight = isDesktop ? 32.0 : 44.0;
    final mentions = matches.firstOrNull is _MentionSuggestion;
    return DecoratedBox(
      key: ValueKey(mentions ? 'mention-suggestions' : 'shortcode-suggestions'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        boxShadow: tokens.shadowMd,
      ),
      child: Material(
        color: tokens.card,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoafRadius.lg),
          side: BorderSide(color: tokens.border),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: mentions ? 240 : 200,
            maxWidth: 320,
          ),
          child: Padding(
            padding: const EdgeInsets.all(LoafSpace.x1),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < matches.length; i++)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => onHover(i),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onPick(matches[i]),
                      child: Container(
                        height: rowHeight,
                        padding: const EdgeInsets.symmetric(
                          horizontal: LoafSpace.x2,
                        ),
                        decoration: BoxDecoration(
                          color: i == highlight
                              ? tokens.border
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(LoafRadius.md),
                        ),
                        child: switch (matches[i]) {
                          _EmojiSuggestion(:final match) => _EmojiRow(match),
                          _MentionSuggestion(:final candidate) => _MentionRow(
                            candidate,
                          ),
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmojiRow extends StatelessWidget {
  const _EmojiRow(this.match);

  final ShortcodeMatch match;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Row(
      children: [
        Text(match.emoji.char, style: const TextStyle(fontSize: 18)),
        const SizedBox(width: LoafSpace.x2),
        Flexible(
          child: Text(
            ':${match.code}:',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: loafMono(13).copyWith(color: tokens.textBody),
          ),
        ),
      ],
    );
  }
}

class _MentionRow extends StatelessWidget {
  const _MentionRow(this.candidate);

  final MentionCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final member = candidate.member;
    final channel = candidate.channel;
    final Widget leading = member != null
        ? LoafAvatar(
            label: member.initials,
            color: member.color,
            size: 22,
            image: member.avatar,
            textStyle: loafBody(10, 600),
          )
        : SizedBox(
            width: 22,
            child: Icon(
              channel!.icon,
              size: 16,
              color: tokens.textMuted,
            ),
          );
    return Row(
      children: [
        leading,
        const SizedBox(width: LoafSpace.x2),
        Flexible(
          child: Text(
            candidate.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: loafBody(14, 600).copyWith(
              color: member != null
                  ? tokens.nameColor(member.role)
                  : tokens.textStrong,
            ),
          ),
        ),
        if (member != null) ...[
          const SizedBox(width: LoafSpace.x2),
          Expanded(
            child: Text(
              member.id,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: loafMono(11).copyWith(color: tokens.textMuted),
            ),
          ),
        ],
      ],
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
                      quoteOf(target.message),
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
  const _IconAction({required this.icon, this.onTap, this.tooltip});

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

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
    final button = GestureDetector(
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
    final tooltip = widget.tooltip;
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
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
