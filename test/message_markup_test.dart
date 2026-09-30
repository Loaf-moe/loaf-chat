import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/message_markup.dart';

/// The one paragraph [blocks] should be, as its runs.
List<Run> _runs(List<Block> blocks) {
  expect(blocks, hasLength(1));
  return (blocks.single as Paragraph).runs;
}

String _text(List<Run> runs) => runs.map((r) => r.text).join();

Run _only(List<Run> runs, String text) =>
    runs.singleWhere((r) => r.text == text);

void main() {
  group('formatted body', () {
    test('bold, italic, strikethrough, underline and inline code', () {
      final runs = _runs(
        parseFormatted(
          '<b>b</b> <strong>B</strong> <i>i</i> <em>I</em> <del>d</del> '
          '<s>s</s> <strike>k</strike> <u>u</u> <code>c</code>',
        ),
      );
      expect(_text(runs), 'b B i I d s k u c');
      expect(_only(runs, 'b').style.bold, isTrue);
      expect(_only(runs, 'B').style.bold, isTrue);
      expect(_only(runs, 'i').style.italic, isTrue);
      expect(_only(runs, 'I').style.italic, isTrue);
      for (final t in ['d', 's', 'k']) {
        expect(_only(runs, t).style.strike, isTrue, reason: t);
      }
      expect(_only(runs, 'u').style.underline, isTrue);
      expect(_only(runs, 'c').style.code, isTrue);
    });

    test('styles nest', () {
      final runs = _runs(parseFormatted('<b>bold <i>both</i></b>'));
      final both = _only(runs, 'both').style;
      expect((both.bold, both.italic), (true, true));
    });

    test('a link keeps its text and opens its target', () {
      final runs = _runs(
        parseFormatted('see <a href="https://loaf.moe/x">the page</a>'),
      );
      expect(_only(runs, 'the page').link, Uri.parse('https://loaf.moe/x'));
      expect(_only(runs, 'see ').link, isNull);
    });

    test('a user permalink is a mention, not a link', () {
      final runs = _runs(
        parseFormatted(
          'hi <a href="https://matrix.to/#/%40ada%3Aexample.com">Ada</a>',
        ),
      );
      final ada = _only(runs, 'Ada');
      expect(ada.mention, '@ada:example.com');
      expect(ada.link, isNull);
    });

    test('a room permalink stays a link', () {
      final runs = _runs(
        parseFormatted('<a href="https://matrix.to/#/#bakery:loaf.moe">x</a>'),
      );
      expect(_only(runs, 'x').link?.host, 'matrix.to');
      expect(_only(runs, 'x').mention, isNull);
    });

    test('<br> breaks the line; other whitespace collapses', () {
      final runs = _runs(parseFormatted('one\n   two<br />three<br>four'));
      expect(_text(runs), 'one two\nthree\nfour');
    });

    test('paragraphs are separate blocks', () {
      final blocks = parseFormatted('<p>one</p><p>two</p>');
      expect(blocks.map((b) => _text((b as Paragraph).runs)), ['one', 'two']);
    });

    test('a code block keeps its text exactly', () {
      final blocks = parseFormatted(
        '<pre><code class="language-dart">if (a &lt; b) {\n  go();\n}\n'
        '</code></pre>',
      );
      expect((blocks.single as CodeBlock).code, 'if (a < b) {\n  go();\n}');
    });

    test('a blockquote holds its own blocks', () {
      final blocks = parseFormatted(
        '<blockquote><p>quoted</p><p><b>twice</b></p></blockquote>after',
      );
      expect(blocks, hasLength(2));
      final quote = blocks.first as Quote;
      expect(quote.children, hasLength(2));
      expect(_text(_runs(blocks.sublist(1))), 'after');
    });

    test('lists, ordered from their start, and nested', () {
      final blocks = parseFormatted(
        '<ol start="3"><li>three</li><li>four<ul><li>inner</li></ul></li></ol>',
      );
      final list = blocks.single as ListBlock;
      expect((list.ordered, list.start, list.items.length), (true, 3, 2));
      final second = list.items[1];
      expect(_text((second.first as Paragraph).runs), 'four');
      final inner = second[1] as ListBlock;
      expect(inner.ordered, isFalse);
      expect(_text((inner.items.single.single as Paragraph).runs), 'inner');
    });

    test('headings and rules', () {
      final blocks = parseFormatted('<h2>Title</h2><hr><p>body</p>');
      expect((blocks[0] as Heading).level, 2);
      expect(_text((blocks[0] as Heading).runs), 'Title');
      expect(blocks[1], isA<Rule>());
    });

    test('each spoiler is numbered, and hides everything inside it', () {
      final runs = _runs(
        parseFormatted(
          '<span data-mx-spoiler>the <b>end</b></span> and '
          '<span data-mx-spoiler="plot">twist</span>',
        ),
      );
      expect(_only(runs, 'the ').spoiler, 0);
      expect(_only(runs, 'end').spoiler, 0);
      expect(_only(runs, ' and ').spoiler, isNull);
      expect(_only(runs, 'twist').spoiler, 1);
    });

    test('the reply fallback is dropped', () {
      final runs = _runs(
        parseFormatted(
          '<mx-reply><blockquote>In reply to <a href="https://matrix.to/#/@a:b">'
          '@a:b</a><br>old</blockquote></mx-reply>new',
        ),
      );
      expect(_text(runs), 'new');
    });

    group('unsafe or unknown', () {
      test('scripts, styles and embeds go, contents and all', () {
        final runs = _runs(
          parseFormatted(
            'a<script>alert(1)</script><style>b{}</style>'
            '<iframe src="https://evil">x</iframe><svg><text>s</text></svg>b',
          ),
        );
        expect(_text(runs), 'ab');
      });

      test('an unknown tag keeps its text and loses its meaning', () {
        final runs = _runs(
          parseFormatted(
            '<marquee>hi</marquee> <font color="red">there</font>',
          ),
        );
        expect(_text(runs), 'hi there');
        expect(runs.every((r) => r.style == RunStyle.plain), isTrue);
      });

      test('a link to anything but the web or mail is just text', () {
        for (final href in [
          'javascript:alert(1)',
          'data:text/html,<b>x</b>',
          'file:///etc/passwd',
          'JaVaScRiPt:alert(1)',
          'vbscript:x',
          'https://',
        ]) {
          final runs = _runs(parseFormatted('<a href="$href">click</a>'));
          expect(_only(runs, 'click').link, isNull, reason: href);
        }
      });

      test('images are their alt text, never loaded', () {
        final runs = _runs(
          parseFormatted(
            'nice <img data-mx-emoticon src="mxc://x/y" alt=":parrot:">',
          ),
        );
        expect(_text(runs), 'nice :parrot:');
      });

      test('event handlers and styles are never read', () {
        final runs = _runs(
          parseFormatted('<b onclick="x()" style="color:red">bold</b>'),
        );
        expect(runs.single.style.bold, isTrue);
      });
    });

    test('with nothing to show, the plain body is used instead', () {
      final blocks = parseMessage(
        formatted: '<mx-reply>quote</mx-reply><script>x</script>',
        body: 'the body',
      );
      expect(_text(_runs(blocks)), 'the body');
    });
  });

  group('plain body', () {
    test('keeps line breaks as typed', () {
      expect(_text(_runs(parsePlain('one\ntwo'))), 'one\ntwo');
      expect(_text(_runs(parsePlain('*one*\ntwo'))), 'one\ntwo');
    });

    test('reads the markdown people type', () {
      final runs = _runs(parsePlain('**bold** _it_ ~~gone~~ `code`'));
      expect(_only(runs, 'bold').style.bold, isTrue);
      expect(_only(runs, 'it').style.italic, isTrue);
      expect(_only(runs, 'gone').style.strike, isTrue);
      expect(_only(runs, 'code').style.code, isTrue);
    });

    test('[text](url) is a link', () {
      final runs = _runs(parsePlain('see [the page](https://loaf.moe)'));
      expect(_only(runs, 'the page').link, Uri.parse('https://loaf.moe'));
    });

    test('quotes, lists and fenced code', () {
      final blocks = parsePlain('> wise\n\n- a\n- b\n\n```\nx < y\n```');
      expect(blocks[0], isA<Quote>());
      expect((blocks[1] as ListBlock).items, hasLength(2));
      expect((blocks[2] as CodeBlock).code, 'x < y');
    });

    test('HTML in a body is text, not markup', () {
      final runs = _runs(parsePlain('<b>not bold</b> & <script>x</script>'));
      expect(_text(runs), '<b>not bold</b> & <script>x</script>');
      expect(runs.every((r) => !r.style.bold), isTrue);
    });

    test('a snake_case word is not emphasis', () {
      expect(
        _text(_runs(parsePlain('call my_func_name now'))),
        'call my_func_name now',
      );
    });
  });

  group('links in text', () {
    Uri? linkOf(String text, String url) =>
        _only(_runs(parsePlain(text)), url).link;

    test('a bare address is a link', () {
      expect(
        linkOf(
          'go to https://loaf.moe/a?b=c#d now',
          'https://loaf.moe/a?b=c#d',
        ),
        Uri.parse('https://loaf.moe/a?b=c#d'),
      );
    });

    test('closing punctuation is not part of it', () {
      for (final (text, url) in [
        ('see https://loaf.moe.', 'https://loaf.moe'),
        ('see https://loaf.moe, then', 'https://loaf.moe'),
        ('really https://loaf.moe/x?!', 'https://loaf.moe/x'),
        ('(https://loaf.moe/x)', 'https://loaf.moe/x'),
        ('"https://loaf.moe/x"', 'https://loaf.moe/x'),
        ('see https://loaf.moe:', 'https://loaf.moe'),
      ]) {
        expect(linkOf(text, url), Uri.parse(url), reason: text);
      }
    });

    test('a bracket the address opened stays in it', () {
      const url = 'https://en.wikipedia.org/wiki/Bread_(disambiguation)';
      expect(linkOf('see $url.', url), Uri.parse(url));
    });

    test('www. addresses open over https', () {
      expect(
        linkOf('www.loaf.moe', 'www.loaf.moe'),
        Uri.parse('https://www.loaf.moe'),
      );
    });

    test('in a formatted body too, but not inside code or a link', () {
      final runs = _runs(
        parseFormatted(
          'at https://a.dev <code>https://b.dev</code> '
          '<a href="https://c.dev">https://d.dev</a>',
        ),
      );
      expect(_only(runs, 'https://a.dev').link, Uri.parse('https://a.dev'));
      expect(_only(runs, 'https://b.dev').link, isNull);
      expect(_only(runs, 'https://d.dev').link, Uri.parse('https://c.dev'));
    });

    test('only web and mail addresses', () {
      expect(safeLink('mailto:a@b.c'), isNotNull);
      expect(safeLink('javascript:alert(1)'), isNull);
    });
  });
}
