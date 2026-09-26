/// Every emoji, findable by name. A sheet on a phone, a popover by the
/// button on a computer. The composer inserts what you pick; a message's
/// "more reactions" reacts with it.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../theme/loaf_theme.dart';
import '../widgets/anchored_popover.dart';
import 'emoji.dart';
import 'emoji_data.dart';

/// This session's recent picks, shared by every picker. Mock state; the
/// SDK phase keeps them in account data.
final emojiRecents = EmojiRecents();

/// Opens the picker and returns the emoji picked, or null. [anchor] is the
/// button that opened it, in global coordinates, for the desktop popover.
Future<String?> showEmojiPicker(BuildContext context, {Rect? anchor}) async {
  final tokens = LoafTokens.of(context);
  String? picked;
  Widget picker(BuildContext context) => EmojiPicker(
    recents: emojiRecents,
    onPick: (emoji) {
      picked = emoji;
      Navigator.pop(context);
    },
  );

  if (isDesktop) {
    await showAnchoredPopover<void>(
      context,
      anchor:
          anchor ??
          Rect.fromCenter(
            center: MediaQuery.sizeOf(context).center(Offset.zero),
            width: 0,
            height: 0,
          ),
      builder: (context) => SizedBox(
        width: _pickerWidth,
        height: _pickerHeight,
        child: picker(context),
      ),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: tokens.card,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(LoafRadius.xxxl),
        ),
      ),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.55,
          child: SafeArea(top: false, child: picker(context)),
        ),
      ),
    );
  }
  final emoji = picked;
  if (emoji != null) emojiRecents.use(emoji);
  return emoji;
}

const _pickerWidth = 352.0;
const _pickerHeight = 400.0;

IconData _iconFor(String group) => switch (group) {
  'Smileys & Emotion' => LucideIcons.smile,
  'People & Body' => LucideIcons.hand,
  'Animals & Nature' => LucideIcons.pawPrint,
  'Food & Drink' => LucideIcons.croissant,
  'Travel & Places' => LucideIcons.car,
  'Activities' => LucideIcons.trophy,
  'Objects' => LucideIcons.lightbulb,
  'Symbols' => LucideIcons.heart,
  'Flags' => LucideIcons.flag,
  _ => LucideIcons.circle,
};

class EmojiPicker extends StatefulWidget {
  const EmojiPicker({
    super.key,
    required this.onPick,
    required this.recents,
    this.groups = emojiGroups,
  });

  final ValueChanged<String> onPick;
  final EmojiRecents recents;
  final List<EmojiGroup> groups;

  @override
  State<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends State<EmojiPicker> {
  final _query = TextEditingController();
  var _group = 0;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final searching = _query.text.trim().isNotEmpty;
    final shown = searching
        ? searchEmoji(_query.text, widget.groups)
        : widget.groups[_group].emoji;
    final recents = widget.recents.emoji;

    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(LoafRadius.md),
          borderSide: BorderSide(color: color, width: width),
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LoafSpace.x3,
        LoafSpace.x2,
        LoafSpace.x3,
        LoafSpace.x2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _query,
            // On a phone the keyboard would cover the grid; on a computer
            // typing to search is the quick way in.
            autofocus: isDesktop,
            style: loafBody(14, 400).copyWith(color: tokens.textStrong),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: Icon(
                LucideIcons.search,
                size: 16,
                color: tokens.textMuted,
              ),
              hintText: 'find an emoji',
              hintStyle: loafBody(14, 400).copyWith(color: tokens.textMuted),
              filled: true,
              fillColor: tokens.sunken,
              border: border(tokens.border),
              enabledBorder: border(tokens.border),
              focusedBorder: border(tokens.borderStrong, 1.5),
            ),
          ),
          if (!searching) ...[
            const SizedBox(height: LoafSpace.x2),
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final (i, group) in widget.groups.indexed)
                    IconButton(
                      tooltip: group.name,
                      isSelected: i == _group,
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _group = i),
                      icon: Icon(
                        _iconFor(group.name),
                        size: 18,
                        color: i == _group ? tokens.accent : tokens.textMuted,
                      ),
                    ),
                ],
              ),
            ),
            if (recents.isNotEmpty) ...[
              _Label(text: 'recent', tokens: tokens),
              SizedBox(
                key: const ValueKey('emoji-recents'),
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final e in recents)
                      _Cell(emoji: e, onTap: () => widget.onPick(e)),
                  ],
                ),
              ),
            ],
            _Label(
              text: widget.groups[_group].name.toLowerCase(),
              tokens: tokens,
            ),
          ] else
            const SizedBox(height: LoafSpace.x2),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text(
                      'no emoji called that',
                      style: loafBody(
                        13,
                        400,
                      ).copyWith(color: tokens.textMuted),
                    ),
                  )
                : GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 44,
                        ),
                    itemCount: shown.length,
                    itemBuilder: (context, i) => Tooltip(
                      message: shown[i].name,
                      waitDuration: const Duration(milliseconds: 600),
                      child: _Cell(
                        emoji: shown[i].char,
                        onTap: () => widget.onPick(shown[i].char),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({required this.text, required this.tokens});

  final String text;
  final LoafTokens tokens;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, LoafSpace.x2, 4, LoafSpace.x1),
    child: Text(
      text.toUpperCase(),
      style: loafBody(
        11,
        600,
      ).copyWith(color: tokens.textMuted, letterSpacing: 0.44),
    ),
  );
}

class _Cell extends StatelessWidget {
  const _Cell({required this.emoji, required this.onTap});

  final String emoji;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(LoafRadius.md),
    child: SizedBox(
      width: 40,
      height: 40,
      child: Center(child: Text(emoji, style: const TextStyle(fontSize: 24))),
    ),
  );
}
