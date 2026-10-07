/// `@person` and `#channel` mentions: what the composer suggests while one is
/// being typed, and how a message carrying them is written for the server.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;

import '../model/models.dart';

enum MentionKind { person, channel }

/// Someone or somewhere the composer can offer after `@` or `#`.
@immutable
class MentionCandidate {
  const MentionCandidate.person(Member this.member)
    : kind = MentionKind.person,
      channel = null;

  const MentionCandidate.channel(Channel this.channel)
    : kind = MentionKind.channel,
      member = null;

  final MentionKind kind;
  final Member? member;
  final Channel? channel;

  /// The Matrix id it points at: a user id or a room id.
  String get id => member?.id ?? channel!.id;

  String get name => member?.name ?? channel!.name;

  /// What goes into the field, sigil and all: `@Ada`, `#kitchen`.
  String get label => '${kind == MentionKind.person ? '@' : '#'}$name';

  Mention get mention => Mention(kind: kind, id: id, label: label);

  @override
  bool operator ==(Object other) =>
      other is MentionCandidate && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// A mention picked into the composer: [label] is the text it left in the
/// field, [id] what that text points at.
@immutable
class Mention {
  const Mention({required this.kind, required this.id, required this.label});

  final MentionKind kind;
  final String id;
  final String label;

  /// A matrix.to permalink, which every client reads as a pill.
  String get link => 'https://matrix.to/#/$id';

  @override
  bool operator ==(Object other) =>
      other is Mention &&
      other.kind == kind &&
      other.id == id &&
      other.label == label;

  @override
  int get hashCode => Object.hash(kind, id, label);

  @override
  String toString() => 'Mention($label → $id)';
}

/// A mention being typed, up to the cursor: `@ad` is `ad` after the `@` at
/// [start]. [query] may be empty: the sigil alone already lists everyone.
typedef MentionQuery = ({int start, MentionKind kind, String query});

/// The mention being typed at [value]'s cursor, if there is one: `@` or `#`
/// at the start of a word, then anything up to the cursor that is not a
/// space. An email address or `C#` is not one, since the sigil is mid-word.
MentionQuery? mentionAt(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  // Mid-composition the text is not settled yet; suggest once it is.
  if (value.composing.isValid && !value.composing.isCollapsed) return null;
  final before = value.text.substring(0, selection.baseOffset);
  final match = _typing.firstMatch(before);
  if (match == null) return null;
  final query = match[2]!;
  return (
    start: before.length - query.length - 1,
    kind: match[1] == '@' ? MentionKind.person : MentionKind.channel,
    query: query,
  );
}

final _typing = RegExp(r'''(?:^|[\s(\[{"'])([@#])([^\s@#]*)$''');

/// Up to [limit] of [candidates] matching [query], best first: a name it
/// starts, then a later word of a name it starts, then a user id's local
/// part it starts, then anything that merely contains it. Ties keep the
/// order given, which is the order the member list and channel list show.
List<MentionCandidate> searchMentions(
  String query,
  Iterable<MentionCandidate> candidates, {
  int limit = 6,
}) {
  final q = query.toLowerCase();
  if (q.isEmpty) return candidates.take(limit).toList();
  final ranked = <(int, int, MentionCandidate)>[];
  var i = 0;
  for (final c in candidates) {
    final rank = _rank(q, c);
    if (rank != null) ranked.add((rank, i, c));
    i++;
  }
  ranked.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  return [for (final r in ranked.take(limit)) r.$3];
}

int? _rank(String q, MentionCandidate c) {
  final name = c.name.toLowerCase();
  if (name.startsWith(q)) return 0;
  if (name.split(RegExp(r'[\s\-_.]+')).skip(1).any((w) => w.startsWith(q))) {
    return 1;
  }
  // @ada:loaf.moe answers to "ada" whatever its display name.
  final local = c.kind == MentionKind.person
      ? c.id.substring(1).split(':').first.toLowerCase()
      : null;
  if (local != null && local.startsWith(q)) return 2;
  if (name.contains(q) || (local?.contains(q) ?? false)) return 3;
  return null;
}

/// The mentions [message] was sent with, read back from its formatted
/// body's permalinks, so editing it keeps them. Only those whose text is
/// in the plain body count: that is the text the edit starts from.
List<Mention> mentionsOf(Message message) {
  final formatted = message.formatted;
  if (formatted == null) return const [];
  final found = <Mention>[];
  for (final a in html.parseFragment(formatted).querySelectorAll('a')) {
    final link = Uri.tryParse(a.attributes['href'] ?? '');
    if (link == null || link.scheme != 'https' || link.host != 'matrix.to') {
      continue;
    }
    var id = Uri.decodeComponent(link.fragment.split('?').first);
    if (id.startsWith('/')) id = id.substring(1);
    // A permalink to an event is a link to a message, not a mention.
    if (id.contains('/')) continue;
    final kind = switch (id.isEmpty ? null : id[0]) {
      '@' => MentionKind.person,
      '!' || '#' => MentionKind.channel,
      _ => null,
    };
    final label = a.text.trim();
    if (kind == null || label.isEmpty) continue;
    found.add(Mention(kind: kind, id: id, label: label));
  }
  return mentionsIn(message.body, found);
}

/// [picked] narrowed to the ones [text] still holds, once each: a mention
/// deleted from the field, or typed over, no longer goes with the message.
List<Mention> mentionsIn(String text, Iterable<Mention> picked) {
  final kept = <Mention>[];
  for (final m in picked) {
    if (kept.contains(m)) continue;
    if (_occurrences(text, m.label).isNotEmpty) kept.add(m);
  }
  return kept;
}

/// [text] with each of [mentions] made a markdown link to its permalink, for
/// the formatted body. The label's `@` and `#` are escaped, or the SDK's own
/// `@name` and pill syntaxes would eat the link text and leave the markdown
/// showing. Code is left as written, as are labels that run on into more of
/// a word (`@Ada` inside `@Adam`). Where two mentions share a label, the one
/// picked last wins.
String linkMentions(String text, List<Mention> mentions) {
  if (mentions.isEmpty) return text;
  final byLabel = {for (final m in mentions) m.label: m};
  // Longest first, so `@Ada Lovelace` is not cut short by `@Ada`.
  final labels = byLabel.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final out = StringBuffer();
  var at = 0;
  for (final segment in _segments(text)) {
    if (segment.code) {
      out.write(text.substring(segment.start, segment.end));
      continue;
    }
    at = segment.start;
    while (at < segment.end) {
      final label = labels.firstWhereOrNull(
        (l) =>
            text.startsWith(l, at) &&
            at + l.length <= segment.end &&
            _boundaryBefore(text, at) &&
            _boundaryAfter(text, at + l.length),
      );
      if (label == null) {
        out.write(text[at]);
        at++;
        continue;
      }
      final m = byLabel[label]!;
      out.write('[${_escapeLinkText(label)}](${m.link})');
      at += label.length;
    }
  }
  return out.toString();
}

/// The Matrix `m.mentions` user ids for [mentions]: people only, since a
/// room has no one to notify.
List<String> mentionedUserIds(List<Mention> mentions) => [
  for (final m in mentions)
    if (m.kind == MentionKind.person) m.id,
];

Iterable<int> _occurrences(String text, String label) sync* {
  for (final s in _segments(text)) {
    if (s.code) continue;
    var from = s.start;
    while (true) {
      final i = text.indexOf(label, from);
      if (i < 0 || i + label.length > s.end) break;
      if (_boundaryBefore(text, i) && _boundaryAfter(text, i + label.length)) {
        yield i;
      }
      from = i + 1;
    }
  }
}

bool _boundaryBefore(String text, int i) =>
    i == 0 || RegExp(r'''[\s(\[{"'*_~>]''').hasMatch(text[i - 1]);

bool _boundaryAfter(String text, int i) =>
    i == text.length || !_wordChar.hasMatch(text[i]);

final _wordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);

String _escapeLinkText(String label) =>
    label.replaceAllMapped(RegExp(r'[\[\]\\@#]'), (m) => '\\${m[0]}');

/// [text] cut into code (fenced, closed or running to the end, and inline)
/// and everything else, in order.
List<({int start, int end, bool code})> _segments(String text) {
  final out = <({int start, int end, bool code})>[];
  var at = 0;
  for (final m in _code.allMatches(text)) {
    if (m.start > at) out.add((start: at, end: m.start, code: false));
    out.add((start: m.start, end: m.end, code: true));
    at = m.end;
  }
  if (at < text.length) out.add((start: at, end: text.length, code: false));
  return out;
}

final _code = RegExp(r'```[\s\S]*?(?:```|$)|`[^`\n]*`');

extension<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
