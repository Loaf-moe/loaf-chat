import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/message_group_tile.dart';
import 'package:loaf_native/ui/channel/message_markup.dart';
import 'package:loaf_native/ui/channel/message_text.dart';
import 'package:loaf_native/ui/channel/timeline_controller.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _you = Member('@you:loaf.moe', 'you', Colors.red);
const _them = Member('@them:loaf.moe', 'them', Colors.blue);

final _mobile = TargetPlatformVariant.only(TargetPlatform.iOS);
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

/// Opened links, instead of a browser.
List<Uri> _captureLinks() {
  final opened = <Uri>[];
  final real = openMessageLink;
  openMessageLink = (url) async {
    opened.add(url);
    return true;
  };
  addTearDown(() => openMessageLink = real);
  return opened;
}

Future<void> _pump(WidgetTester tester, {String? formatted, String? body}) {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final controller = TimelineController([
    Message(
      id: '1',
      author: _them,
      sentAt: DateTime(2026, 9, 24, 10),
      body: body ?? '',
      formatted: formatted,
    ),
  ], you: _you);
  addTearDown(controller.dispose);
  return tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(40),
          child: MessageGroupTile(
            group: MessageGroup(controller.messages),
            controller: controller,
          ),
        ),
      ),
    ),
  );
}

/// The span drawing [text], wherever it is in the message.
TextSpan _spanOf(WidgetTester tester, String text) {
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    TextSpan? found;
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.text == text) {
        found = span;
        return false;
      }
      return true;
    });
    if (found != null) return found!;
  }
  throw StateError('no span "$text"');
}

/// Where [text] is drawn, for a pointer to go to.
Offset _centreOf(WidgetTester tester, String text) {
  for (final element in find.byType(RichText).evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    final plain = paragraph.text.toPlainText();
    final at = plain.indexOf(text);
    if (at < 0) continue;
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: at, extentOffset: at + text.length),
    );
    final rect = boxes.first.toRect();
    return paragraph.localToGlobal(rect.center);
  }
  throw StateError('no text "$text"');
}

void main() {
  testWidgets(
    'a link in selectable text opens in the browser',
    variant: _desktop,
    (tester) async {
      final opened = _captureLinks();
      await _pump(tester, body: 'see https://loaf.moe/bread. yum');
      expect(find.byType(SelectionArea), findsOneWidget);

      await tester.tapAt(_centreOf(tester, 'https://loaf.moe/bread'));
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse('https://loaf.moe/bread')]);
    },
  );

  testWidgets('a link opens on a tap on a phone', variant: _mobile, (
    tester,
  ) async {
    final opened = _captureLinks();
    await _pump(
      tester,
      formatted: 'read <a href="https://loaf.moe/x">this</a>',
      body: 'read this',
    );
    await tester.tapAt(_centreOf(tester, 'this'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://loaf.moe/x')]);
  });

  testWidgets('hovering a link shows where it goes', variant: _desktop, (
    tester,
  ) async {
    await _pump(
      tester,
      formatted: 'read <a href="https://loaf.moe/real">this</a>',
      body: 'read this',
    );
    expect(find.text('https://loaf.moe/real'), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(_centreOf(tester, 'this'));
    await tester.pumpAndSettle();
    expect(find.text('https://loaf.moe/real'), findsOneWidget);

    await mouse.moveTo(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('https://loaf.moe/real'), findsNothing);
  });

  testWidgets('a phone never shows the address preview', variant: _mobile, (
    tester,
  ) async {
    await _pump(
      tester,
      formatted: '<a href="https://loaf.moe/real">this</a>',
      body: 'this',
    );
    expect(_spanOf(tester, 'this').onEnter, isNull);
  });

  testWidgets('a spoiler is hidden until tapped', (tester) async {
    await _pump(
      tester,
      formatted: 'it was <span data-mx-spoiler>the baker</span>',
      body: 'it was the baker',
    );
    final tokens = loafLightTheme().extension<LoafTokens>()!;
    final hidden = _spanOf(tester, 'the baker').style!;
    expect(hidden.color, hidden.backgroundColor);

    await tester.tapAt(_centreOf(tester, 'the baker'));
    await tester.pumpAndSettle();
    final shown = _spanOf(tester, 'the baker').style!;
    expect(shown.color, isNot(shown.backgroundColor));
    expect(shown.color, tokens.textBody);
  });

  testWidgets('code, quotes and lists draw as blocks', (tester) async {
    await _pump(
      tester,
      formatted:
          '<blockquote>wise words</blockquote>'
          '<ol><li>first</li><li>second</li></ol>'
          '<pre><code>let x = 1;</code></pre>',
      body: '',
    );
    expect(find.text('wise words'), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(find.text('let x = 1;'), findsOneWidget);
    final code = tester.widget<Text>(find.text('let x = 1;'));
    expect(code.style?.fontFamily, 'IBM Plex Mono');
  });

  testWidgets('bold is drawn bold, in the variable font', (tester) async {
    await _pump(tester, formatted: '<b>loud</b> quiet', body: 'loud quiet');
    final loud = _spanOf(tester, 'loud').style!;
    expect(loud.fontWeight, FontWeight.w600);
    expect(loud.fontVariations, [const FontVariation('wght', 600)]);
  });

  testWidgets('a mention of you stands out from a mention of anyone else', (
    tester,
  ) async {
    await _pump(
      tester,
      formatted:
          '<a href="https://matrix.to/#/@you:loaf.moe">you</a> and '
          '<a href="https://matrix.to/#/@ada:loaf.moe">Ada</a>',
      body: 'you and Ada',
    );
    final tokens = loafLightTheme().extension<LoafTokens>()!;
    expect(_spanOf(tester, 'you').style!.backgroundColor, tokens.accentSoft);
    expect(_spanOf(tester, 'Ada').style!.backgroundColor, tokens.border);
    // A pill names someone; it is not a link to follow.
    expect(_spanOf(tester, 'Ada').recognizer, isNull);
  });

  test('a quote of a message reads as one line of its text', () {
    expect(
      plainTextOf(
        parseFormatted('<p><b>one</b></p><ul><li>two</li></ul>line<br>three'),
      ),
      'one two line three',
    );
  });
}
