/// What a message says, as blocks of styled runs: parsed from its Matrix
/// `formatted_body`, or read from a plain `body` as the markdown people type.
///
/// Only the subset of HTML the Matrix spec recommends is understood, and it
/// is understood rather than trusted: nothing here loads, runs or embeds.
/// A tag outside the subset keeps its text and loses its meaning, a link
/// that is not to the web or mail is just its text, and scripts, styles and
/// the reply fallback go with everything inside them.
library;

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:markdown/markdown.dart' as md;

/// How a run of text is set, independently of where it links.
@immutable
class RunStyle {
  const RunStyle({
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.underline = false,
    this.code = false,
  });

  static const plain = RunStyle();

  final bool bold;
  final bool italic;
  final bool strike;
  final bool underline;
  final bool code;

  RunStyle copyWith({
    bool? bold,
    bool? italic,
    bool? strike,
    bool? underline,
    bool? code,
  }) => RunStyle(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    strike: strike ?? this.strike,
    underline: underline ?? this.underline,
    code: code ?? this.code,
  );

  @override
  bool operator ==(Object other) =>
      other is RunStyle &&
      other.bold == bold &&
      other.italic == italic &&
      other.strike == strike &&
      other.underline == underline &&
      other.code == code;

  @override
  int get hashCode => Object.hash(bold, italic, strike, underline, code);
}

/// A stretch of text that is set, and behaves, one way throughout.
@immutable
class Run {
  const Run(
    this.text, {
    this.style = RunStyle.plain,
    this.link,
    this.mention,
    this.spoiler,
  });

  final String text;
  final RunStyle style;

  /// Where tapping it goes, in the browser. Always http(s), ftp, mailto or
  /// magnet: see [safeLink].
  final Uri? link;

  /// The Matrix user it names, when it is a mention pill rather than a link.
  final String? mention;

  /// Which of the message's spoilers it belongs to. Every run of one
  /// spoiler shares the number, so revealing one reveals it all.
  final int? spoiler;

  bool _sameAs(Run other) =>
      other.style == style &&
      other.link == link &&
      other.mention == mention &&
      other.spoiler == spoiler;

  Run _withText(String text) =>
      Run(text, style: style, link: link, mention: mention, spoiler: spoiler);

  @override
  String toString() =>
      'Run(${['"$text"', if (style.bold) 'bold', if (style.italic) 'italic', if (style.strike) 'strike', if (style.underline) 'underline', if (style.code) 'code', if (link != null) 'link: $link', if (mention != null) 'mention: $mention', if (spoiler != null) 'spoiler: $spoiler'].join(', ')})';
}

sealed class Block {
  const Block();
}

/// Running text; `\n` in a run is a line break.
final class Paragraph extends Block {
  const Paragraph(this.runs);
  final List<Run> runs;
}

final class Heading extends Block {
  const Heading(this.level, this.runs);
  final int level;
  final List<Run> runs;
}

/// Preformatted code, exactly as written.
final class CodeBlock extends Block {
  const CodeBlock(this.code);
  final String code;
}

final class Quote extends Block {
  const Quote(this.children);
  final List<Block> children;
}

final class ListBlock extends Block {
  const ListBlock({required this.ordered, required this.items, this.start = 1});
  final bool ordered;
  final int start;
  final List<List<Block>> items;
}

final class Rule extends Block {
  const Rule();
}

/// The message as blocks: its [formatted] HTML when that has anything to
/// show, otherwise its plain [body]. Parsed once per distinct text, since
/// the timeline rebuilds every visible message on each change.
List<Block> parseMessage({String? formatted, required String body}) {
  final key = formatted ?? '\u0000$body';
  final cached = _cache.remove(key);
  if (cached != null) return _cache[key] = cached;
  var blocks = formatted == null ? const <Block>[] : parseFormatted(formatted);
  if (!_hasText(blocks)) blocks = parsePlain(body);
  _cache[key] = blocks;
  if (_cache.length > 512) _cache.remove(_cache.keys.first);
  return blocks;
}

// Insertion-ordered: removing and re-adding on a hit keeps the least
// recently read first, which is the one to drop.
final _cache = <String, List<Block>>{};

bool _hasText(List<Block> blocks) => blocks.any(
  (b) => switch (b) {
    Paragraph(:final runs) ||
    Heading(:final runs) => runs.any((r) => r.text.trim().isNotEmpty),
    CodeBlock(:final code) => code.trim().isNotEmpty,
    Quote(:final children) => _hasText(children),
    ListBlock(:final items) => items.any(_hasText),
    Rule() => true,
  },
);

/// [formatted] — a Matrix `formatted_body` — read through the spec's
/// recommended subset of HTML. Whitespace collapses as a browser would;
/// `<br>` is the line break.
List<Block> parseFormatted(String formatted) {
  final builder = _Builder(keepNewlines: false);
  builder.walkAll(html.parseFragment(formatted).nodes, RunStyle.plain);
  return builder.finish();
}

/// A plain [body], read as the markdown people type in chat — `**bold**`,
/// `> quote`, fenced code — keeping each line break as written. Nothing in
/// it is ever taken as HTML.
List<Block> parsePlain(String body) {
  if (!_markdownish.hasMatch(body)) {
    final builder = _Builder(keepNewlines: true)..add(body, RunStyle.plain);
    return builder.finish();
  }
  final document = md.Document(
    extensionSet: md.ExtensionSet.none,
    blockSyntaxes: _chatBlocks,
    inlineSyntaxes: [md.StrikethroughSyntax(), md.AutolinkExtensionSyntax()],
    withDefaultBlockSyntaxes: false,
  );
  // Rendered and read back, so the text comes out exactly as escaped once.
  final rendered = md.renderToHtml(document.parse(body));
  final builder = _Builder(keepNewlines: true);
  builder.walkAll(html.parseFragment(rendered).nodes, RunStyle.plain);
  return builder.finish();
}

/// Markdown as people write it in chat. No raw HTML blocks or inline HTML:
/// a body is text, and `<b>` in one is someone typing angle brackets. No
/// indented code or underlined headings either, which catch pasted text
/// and a line of dashes by surprise.
const _chatBlocks = <md.BlockSyntax>[
  md.EmptyBlockSyntax(),
  md.HeaderSyntax(),
  md.FencedCodeBlockSyntax(),
  md.BlockquoteSyntax(),
  md.HorizontalRuleSyntax(),
  md.UnorderedListSyntax(),
  md.OrderedListSyntax(),
  md.TableSyntax(),
  md.ParagraphSyntax(),
];

/// Anything markdown would read differently from plain text. Without one
/// the body is taken as it is, which is both quicker and immune to
/// markdown's own surprises.
final _markdownish = RegExp(
  r'[*_~`>#\[\\|]|^\s*(?:[-+]|\d+[.)])\s',
  multiLine: true,
);

/// [raw] as a link the browser may open, or null. The Matrix spec's
/// schemes only: anything else — `javascript:`, `data:`, `file:`, an app's
/// own scheme — is shown as text and never opened.
Uri? safeLink(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !_schemes.contains(uri.scheme.toLowerCase())) return null;
  // A web link with nowhere to go is not one.
  if (uri.scheme.startsWith('http') && uri.host.isEmpty) return null;
  return uri;
}

const _schemes = {'http', 'https', 'ftp', 'mailto', 'magnet'};

/// The Matrix user a link points at, when it is a mention: a matrix.to
/// permalink or a `matrix:u/` URI to a user id.
String? mentionOf(Uri link) {
  if (link.scheme == 'https' && link.host == 'matrix.to') {
    final id = Uri.decodeComponent(link.fragment.split('?').first);
    final user = id.startsWith('/') ? id.substring(1) : id;
    return user.startsWith('@') && user.contains(':') ? user : null;
  }
  return null;
}

/// Bare web addresses in [text], as link runs among plain ones. Closing
/// punctuation is not part of the address — "see https://x.dev." links
/// x.dev — unless it closes a bracket the address opened, as Wikipedia's
/// do.
List<Run> linkify(String text, Run template) {
  final runs = <Run>[];
  var at = 0;
  for (final match in _bareUrl.allMatches(text)) {
    final url = _trimTrailing(match[0]!);
    final link = safeLink(url.startsWith('www.') ? 'https://$url' : url);
    if (link == null) continue;
    if (match.start > at) {
      runs.add(template._withText(text.substring(at, match.start)));
    }
    runs.add(Run(url, style: template.style, link: link));
    at = match.start + url.length;
  }
  if (runs.isEmpty) return [template._withText(text)];
  if (at < text.length) runs.add(template._withText(text.substring(at)));
  return runs;
}

final _bareUrl = RegExp(
  r'\b(?:https?://|www\.)[^\s<>"]+',
  caseSensitive: false,
);

String _trimTrailing(String url) {
  var end = url.length;
  while (end > 0) {
    final last = url[end - 1];
    final body = url.substring(0, end);
    if ('.,:;!?\'"*_~'.contains(last)) {
      end--;
    } else if (last == ')' && _count(body, ')') > _count(body, '(')) {
      end--;
    } else if (last == ']' && _count(body, ']') > _count(body, '[')) {
      end--;
    } else {
      break;
    }
  }
  return url.substring(0, end);
}

int _count(String s, String char) => char.allMatches(s).length;

/// Walks HTML into blocks. Inline content gathers into the current
/// paragraph until a block-level tag ends it.
class _Builder {
  _Builder({required this.keepNewlines, _Counter? spoilers})
    : _spoilers = spoilers ?? _Counter();

  /// Whether a newline in text is a line break (a plain body) or just
  /// whitespace (HTML, where `<br>` is the break).
  final bool keepNewlines;

  final _Counter _spoilers;
  final _blocks = <Block>[];
  var _runs = <Run>[];

  /// Set while inside a spoiler; its runs carry the number.
  int? _spoiler;

  /// Set while inside a link.
  Uri? _link;
  String? _mention;

  _Builder _child() =>
      _Builder(keepNewlines: keepNewlines, spoilers: _spoilers)
        .._spoiler = _spoiler;

  List<Block> finish() {
    _flush();
    return _blocks;
  }

  void add(String text, RunStyle style) {
    var t = keepNewlines
        ? text.replaceAll(RegExp(r'[ \t\r\f]+'), ' ')
        : text.replaceAll(RegExp(r'\s+'), ' ');
    // One space between words, however many the markup had around tags.
    final prev = _runs.isEmpty ? '' : _runs.last.text;
    if (t.startsWith(' ') &&
        (prev.isEmpty || prev.endsWith(' ') || prev.endsWith('\n'))) {
      t = t.substring(1);
    }
    if (t.isEmpty) return;
    final run = Run(
      t,
      style: style,
      link: _link,
      mention: _mention,
      spoiler: _spoiler,
    );
    // Addresses already inside a link, or in code, stay as they are.
    _runs.addAll(run.link == null && !style.code ? linkify(t, run) : [run]);
  }

  void _lineBreak() => _runs.add(Run('\n', spoiler: _spoiler));

  /// Ends the paragraph being gathered, if it has anything in it.
  void _flush() {
    final runs = _tidy(_runs);
    _runs = [];
    if (runs.isNotEmpty) _blocks.add(Paragraph(runs));
  }

  void _block(Block block) {
    _flush();
    _blocks.add(block);
  }

  void walkAll(Iterable<dom.Node> nodes, RunStyle style) {
    for (final node in nodes) {
      _walk(node, style);
    }
  }

  void _walk(dom.Node node, RunStyle style) {
    if (node is dom.Text) {
      add(node.text, style);
      return;
    }
    if (node is! dom.Element) return; // Comments, doctypes.
    final tag = node.localName ?? '';
    if (_dropped.contains(tag)) return;
    switch (tag) {
      case 'br':
        _lineBreak();
      case 'b' || 'strong':
        walkAll(node.nodes, style.copyWith(bold: true));
      case 'i' || 'em':
        walkAll(node.nodes, style.copyWith(italic: true));
      case 's' || 'del' || 'strike':
        walkAll(node.nodes, style.copyWith(strike: true));
      case 'u' || 'ins':
        walkAll(node.nodes, style.copyWith(underline: true));
      case 'code':
        walkAll(node.nodes, style.copyWith(code: true));
      case 'a':
        _anchor(node, style);
      case 'span' when node.attributes.containsKey('data-mx-spoiler'):
        final outer = _spoiler;
        _spoiler = _spoilers.next();
        walkAll(node.nodes, style);
        _spoiler = outer;
      case 'img':
        // Custom emotes and inline images are not drawn: their alt text
        // (":party_parrot:") says what they were.
        final alt = node.attributes['alt'] ?? node.attributes['title'];
        if (alt != null) add(alt, style);
      case 'pre':
        // The text, verbatim: whitespace is the point of a code block.
        final code = node.text.replaceFirst(RegExp(r'\n$'), '');
        _block(CodeBlock(code));
      case 'blockquote':
        final inner = _child()..walkAll(node.nodes, style);
        _block(Quote(inner.finish()));
      case 'ul' || 'ol':
        _list(node, style);
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        _flush();
        walkAll(node.nodes, style);
        final runs = _tidy(_runs);
        _runs = [];
        if (runs.isNotEmpty) _blocks.add(Heading(int.parse(tag[1]), runs));
      case 'hr':
        _block(const Rule());
      case 'td' || 'th':
        // Tables are flattened a row to a line; cells are set apart.
        if (node.previousElementSibling != null) add(' · ', style);
        walkAll(node.nodes, tag == 'th' ? style.copyWith(bold: true) : style);
      case _ when _blockTags.contains(tag):
        _flush();
        walkAll(node.nodes, style);
        _flush();
      default:
        // Outside the subset — <font>, <sup>, anything invented — the text
        // stays and the tag's meaning goes.
        walkAll(node.nodes, style);
    }
  }

  void _anchor(dom.Element node, RunStyle style) {
    final href = node.attributes['href'];
    final link = href == null ? null : safeLink(href);
    final mention = link == null ? null : mentionOf(link);
    final outerLink = _link;
    final outerMention = _mention;
    if (mention != null) {
      _mention = mention;
    } else if (link != null) {
      _link = link;
    }
    walkAll(node.nodes, style);
    _link = outerLink;
    _mention = outerMention;
  }

  void _list(dom.Element node, RunStyle style) {
    final items = <List<Block>>[];
    for (final child in node.nodes) {
      if (child is dom.Text && child.text.trim().isEmpty) continue;
      final item = _child();
      if (child is dom.Element && child.localName == 'li') {
        item.walkAll(child.nodes, style);
      } else {
        item._walk(child, style);
      }
      final blocks = item.finish();
      if (blocks.isNotEmpty) items.add(blocks);
    }
    if (items.isEmpty) return;
    final start = int.tryParse(node.attributes['start'] ?? '') ?? 1;
    _block(
      ListBlock(ordered: node.localName == 'ol', items: items, start: start),
    );
  }
}

class _Counter {
  var _n = 0;
  int next() => _n++;
}

/// Gone with everything inside them. The reply fallback repeats the quoted
/// message, which the timeline already shows above; the rest is not text.
const _dropped = {
  'mx-reply',
  'script',
  'style',
  'head',
  'title',
  'template',
  'iframe',
  'frame',
  'frameset',
  'object',
  'embed',
  'applet',
  'noscript',
  'svg',
  'math',
  'canvas',
  'audio',
  'video',
  'form',
  'input',
  'button',
  'select',
  'textarea',
  'link',
  'meta',
  'base',
};

/// Tags that stand on their own lines, drawn as the paragraphs inside them.
const _blockTags = {
  'p',
  'div',
  'li',
  'table',
  'thead',
  'tbody',
  'tfoot',
  'tr',
  'caption',
  'details',
  'summary',
  'dl',
  'dt',
  'dd',
  'section',
  'article',
  'header',
  'footer',
  'aside',
  'nav',
  'main',
  'figure',
  'figcaption',
  'address',
};

/// Joins neighbouring runs set the same way, and trims the spaces a line
/// starts or ends with, which markup leaves around tags and line breaks.
List<Run> _tidy(List<Run> runs) {
  final merged = <Run>[];
  for (final run in runs) {
    if (merged.isNotEmpty && merged.last._sameAs(run)) {
      merged.last = merged.last._withText(merged.last.text + run.text);
    } else {
      merged.add(run);
    }
  }
  final last = merged.length - 1;
  for (var i = 0; i <= last; i++) {
    var text = merged[i].text.replaceAll(RegExp(r' *\n *'), '\n');
    if (i == 0) {
      text = text.trimLeft();
    } else if (merged[i - 1].text.endsWith('\n')) {
      text = text.replaceFirst(RegExp(r'^ +'), '');
    }
    if (i == last) {
      text = text.trimRight();
    } else if (merged[i + 1].text.startsWith('\n')) {
      text = text.replaceFirst(RegExp(r' +$'), '');
    }
    merged[i] = merged[i]._withText(text);
  }
  merged.removeWhere((r) => r.text.isEmpty);
  // Trailing line breaks are left by a <br> before a block ends.
  while (merged.isNotEmpty && merged.last.text.trim().isEmpty) {
    merged.removeLast();
  }
  return merged;
}
