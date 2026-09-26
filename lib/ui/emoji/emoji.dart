/// Emoji as the picker knows them: Unicode's groups and names, generated
/// into emoji_data.dart by tool/gen_emoji.dart.
library;

import 'package:flutter/foundation.dart';

@immutable
class Emoji {
  const Emoji(this.char, this.name);

  final String char;

  /// Unicode's CLDR short name, such as "baguette bread". What search
  /// matches.
  final String name;
}

@immutable
class EmojiGroup {
  const EmojiGroup(this.name, this.emoji);

  final String name;
  final List<Emoji> emoji;
}

/// Emoji whose names contain [query]. Names where it starts a word come
/// first — "bread" finds 🍞 bread before 🫓 flatbread — then Unicode order.
List<Emoji> searchEmoji(String query, List<EmojiGroup> groups) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final words = <Emoji>[];
  final inside = <Emoji>[];
  for (final group in groups) {
    for (final e in group.emoji) {
      final name = e.name.toLowerCase();
      if (!name.contains(q)) continue;
      final startsWord = name.startsWith(q) || name.contains(' $q');
      (startsWord ? words : inside).add(e);
    }
  }
  return [...words, ...inside];
}

/// Emoji you have picked lately, newest first. This session's only; a real
/// client keeps them in account data (`io.element.recent_emoji`) so they
/// follow you between devices.
class EmojiRecents extends ChangeNotifier {
  EmojiRecents({this.limit = 16});

  final int limit;
  final _emoji = <String>[];

  List<String> get emoji => List.unmodifiable(_emoji);

  void use(String emoji) {
    _emoji
      ..remove(emoji)
      ..insert(0, emoji);
    if (_emoji.length > limit) _emoji.removeLast();
    notifyListeners();
  }
}
