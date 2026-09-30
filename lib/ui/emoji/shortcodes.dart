/// `:shortcode:` emoji: what the composer suggests while one is being typed,
/// and what it turns them into on send.
library;

import 'package:flutter/services.dart';

import 'emoji.dart';
import 'emoji_data.dart';

/// Every shortcode in [emojiGroups]. Built on first use: nothing pays for
/// it until someone types a colon.
final shortcodes = ShortcodeIndex(emojiGroups);

/// A suggestion: [emoji], under the one of its shortcodes that matched.
typedef ShortcodeMatch = ({String code, Emoji emoji});

/// A shortcode being typed, up to the cursor: `:smi` is `smi` from the
/// colon at [start].
typedef ShortcodeQuery = ({int start, String query});

class ShortcodeIndex {
  ShortcodeIndex(this._groups);

  final List<EmojiGroup> _groups;

  late final Map<String, Emoji> _byCode = {
    for (final group in _groups)
      for (final emoji in group.emoji)
        for (final code in emoji.shortcodes) code: emoji,
  };

  Emoji? operator [](String code) => _byCode[code];

  /// Up to [limit] emoji whose shortcodes match [query], one entry each:
  /// an exact match, then shortcodes it starts (shortest first, so `smi`
  /// offers smile before smiling_face_with_halo), then ones where it starts
  /// a later word, then ones that merely contain it.
  List<ShortcodeMatch> search(String query, {int limit = 8}) {
    final q = query.toLowerCase();
    if (q.isEmpty) return const [];
    final best = <Emoji, (int, String)>{};
    for (final MapEntry(key: code, value: emoji) in _byCode.entries) {
      final rank = code == q
          ? 0
          : code.startsWith(q)
          ? 1
          : code.contains('_$q')
          ? 2
          : code.contains(q)
          ? 3
          : null;
      if (rank == null) continue;
      final seen = best[emoji];
      if (seen == null || _before((rank, code), seen)) {
        best[emoji] = (rank, code);
      }
    }
    final ranked = best.entries.toList()
      ..sort((a, b) => _before(a.value, b.value) ? -1 : 1);
    return [
      for (final e in ranked.take(limit)) (code: e.value.$2, emoji: e.key),
    ];
  }

  static bool _before((int, String) a, (int, String) b) {
    if (a.$1 != b.$1) return a.$1 < b.$1;
    if (a.$2.length != b.$2.length) return a.$2.length < b.$2.length;
    return a.$2.compareTo(b.$2) < 0;
  }

  /// [text] with each known `:shortcode:` made its emoji. Code is left as
  /// written — a `:smile:` in backticks is someone showing the syntax — and
  /// so is anything unknown, which may be a time or an emote pack's.
  String expand(String text) => text.replaceAllMapped(_codeOrShortcode, (m) {
    final code = m[1];
    if (code == null) return m[0]!;
    return _byCode[code]?.char ?? m[0]!;
  });

  /// Fenced code (closed or running to the end), inline code, or a
  /// shortcode, in that order so code swallows what is inside it.
  static final _codeOrShortcode = RegExp(
    r'```[\s\S]*?(?:```|$)|`[^`\n]*`|:([a-z0-9_+\-]+):',
  );
}

/// The shortcode being typed at [value]'s cursor, if there is one: a colon
/// at the start of a word, then at least two of the characters shortcodes
/// are made of, ending at the cursor. Two, because one letter matches half
/// the table, and `:)` or `:D` is a smiley on its own.
ShortcodeQuery? shortcodeAt(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  // Mid-composition the text is not settled yet; suggest once it is.
  if (value.composing.isValid && !value.composing.isCollapsed) return null;
  final before = value.text.substring(0, selection.baseOffset);
  final match = _typing.firstMatch(before);
  if (match == null) return null;
  final query = match[1]!;
  return (start: before.length - query.length - 1, query: query.toLowerCase());
}

final _typing = RegExp(r'''(?:^|[\s(\[{"']):([a-zA-Z0-9_+\-]{2,})$''');
