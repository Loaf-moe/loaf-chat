import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/link_preview_card.dart';
import 'package:loaf_native/ui/channel/message_text.dart';
import 'package:loaf_native/ui/model/link_previews.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

final _link = Uri.parse('https://loaf.moe/bake');

/// Previews the test answers by hand.
class _Scripted implements LinkPreviews {
  final state = ValueNotifier<LinkPreviewState>(const LinkPreviewLoading());
  final asked = <Uri>[];

  @override
  ValueListenable<LinkPreviewState> of(Uri link) {
    asked.add(link);
    return state;
  }

  void ready({
    String? title = 'Bake day',
    String? description = 'Flour, water, salt and time.',
    ImageProvider? image,
  }) => state.value = LinkPreviewReady(
    LinkPreview.of(title: title, description: description, image: image)!,
  );
}

/// Previews with a state of its own for each link.
class _PerLink implements LinkPreviews {
  final states = <Uri, ValueNotifier<LinkPreviewState>>{};

  @override
  ValueListenable<LinkPreviewState> of(Uri link) =>
      states.putIfAbsent(link, () => ValueNotifier(const LinkPreviewLoading()));

  void ready(Uri link, String title) => (of(link) as ValueNotifier).value =
      LinkPreviewReady(LinkPreview.of(title: title)!);
}

/// A picture that never arrives: its box is laid out all the same.
class _Pending extends ImageProvider<_Pending> {
  @override
  Future<_Pending> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Pending key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
}

class _Broken extends ImageProvider<_Broken> {
  @override
  Future<_Broken> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Broken key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(Future.error(StateError('no picture')));
}

Future<void> _pump(
  WidgetTester tester,
  LinkPreviews previews, {
  double column = 600,
  Uri? link,
  double textScale = 1,
}) => tester.pumpWidget(
  MaterialApp(
    theme: loafDarkTheme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: LinkPreviewsScope(
      previews: previews,
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: column,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [LinkPreviewCard(link: link ?? _link)],
            ),
          ),
        ),
      ),
    ),
  ),
);

const _slow = Duration(milliseconds: 300);

void main() {
  final line = find.byKey(LinkPreviewCard.lineKey);
  final card = find.byKey(LinkPreviewCard.cardKey);
  double heightOf(WidgetTester tester) =>
      tester.getSize(find.byType(LinkPreviewCard)).height;

  final desktop = TargetPlatformVariant.only(TargetPlatform.linux);
  final phone = TargetPlatformVariant.only(TargetPlatform.iOS);

  testWidgets('a link still being asked about draws nothing at first', (
    tester,
  ) async {
    await _pump(tester, _Scripted());
    await tester.pump(_slow - const Duration(milliseconds: 1));
    expect(line, findsNothing);
    expect(card, findsNothing);
    expect(heightOf(tester), 0);
  });

  testWidgets('one that is slow to answer says it is loading', (tester) async {
    await _pump(tester, _Scripted());
    await tester.pump(_slow);
    expect(line, findsOneWidget);
    expect(find.text('loading preview…'), findsOneWidget);
    expect(card, findsNothing);
  });

  testWidgets('a preview is a card 88 high, naming the site', (tester) async {
    final previews = _Scripted();
    await _pump(tester, previews);
    previews.ready();
    await tester.pump();
    expect(tester.getSize(card).height, 88);
    expect(find.text('loaf.moe'), findsOneWidget);
    expect(find.text('Bake day'), findsOneWidget);
    expect(find.text('Flour, water, salt and time.'), findsOneWidget);
  });

  testWidgets('a quick answer never shows the loading line', (tester) async {
    final previews = _Scripted();
    await _pump(tester, previews);
    previews.ready();
    await tester.pump();
    await tester.pump(_slow);
    expect(line, findsNothing);
    expect(card, findsOneWidget);
  });

  testWidgets('the card takes the loading line\'s place', (tester) async {
    final previews = _Scripted();
    await _pump(tester, previews);
    await tester.pump(_slow);
    previews.ready();
    await tester.pump();
    expect(line, findsNothing);
    expect(card, findsOneWidget);
  });

  testWidgets('a link with no preview draws nothing', (tester) async {
    final previews = _Scripted()..state.value = const LinkPreviewNone();
    await _pump(tester, previews);
    await tester.pump(_slow);
    expect(line, findsNothing);
    expect(card, findsNothing);
    expect(heightOf(tester), 0);
  });

  testWidgets('a slow answer of nothing takes the loading line away', (
    tester,
  ) async {
    final previews = _Scripted();
    await _pump(tester, previews);
    await tester.pump(_slow);
    previews.state.value = const LinkPreviewNone();
    await tester.pump();
    expect(line, findsNothing);
    expect(heightOf(tester), 0);
  });

  testWidgets('a link asked about again waits before saying so again', (
    tester,
  ) async {
    final previews = _Scripted()..state.value = const LinkPreviewNone();
    await _pump(tester, previews);
    previews.state.value = const LinkPreviewLoading();
    await tester.pump();
    expect(line, findsNothing);
    await tester.pump(_slow);
    expect(line, findsOneWidget);
  });

  testWidgets('a tap opens the link', (tester) async {
    final opened = <Uri>[];
    final real = openMessageLink;
    openMessageLink = (url) async {
      opened.add(url);
      return true;
    };
    addTearDown(() => openMessageLink = real);
    final previews = _Scripted();
    await _pump(tester, previews);
    previews.ready();
    await tester.pump();
    await tester.tap(card);
    expect(opened, [_link]);
  });

  testWidgets('a picture sits at the left, 88 square, with the words beside', (
    tester,
  ) async {
    final previews = _Scripted();
    await _pump(tester, previews);
    previews.ready(image: _Pending());
    await tester.pump();
    final picture = find.descendant(of: card, matching: find.byType(Image));
    expect(tester.getSize(picture), const Size(88, 88));
    expect(
      tester.getTopLeft(find.text('Bake day')).dx,
      greaterThan(tester.getTopRight(picture).dx),
    );
  });

  testWidgets('without a picture the words start at the card\'s edge', (
    tester,
  ) async {
    final previews = _Scripted();
    await _pump(tester, previews);
    previews.ready();
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('Bake day')).dx - tester.getTopLeft(card).dx,
      lessThan(88),
    );
  });

  testWidgets('a picture that fails to load leaves the card and its words', (
    tester,
  ) async {
    final previews = _Scripted();
    await _pump(tester, previews);
    previews.ready(image: _Broken());
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(card).height, 88);
    expect(
      tester.getTopLeft(find.text('Bake day')).dx - tester.getTopLeft(card).dx,
      lessThan(88),
    );
  });

  testWidgets('a picture alone is still a card', (tester) async {
    final previews = _Scripted();
    await _pump(tester, previews);
    previews.ready(title: null, description: null, image: _Pending());
    await tester.pump();
    expect(tester.getSize(card).height, 88);
    expect(find.text('loaf.moe'), findsOneWidget);
  });

  testWidgets('on a computer the card is at most 400 wide', (tester) async {
    final previews = _Scripted()..ready();
    await _pump(tester, previews, column: 600);
    expect(tester.getSize(card).width, 400);
    await _pump(tester, previews, column: 300);
    expect(tester.getSize(card).width, 300);
  }, variant: desktop);

  testWidgets('on a phone the card fills the column', (tester) async {
    final previews = _Scripted()..ready();
    await _pump(tester, previews, column: 600);
    expect(tester.getSize(card).width, 600);
  }, variant: phone);

  testWidgets('large text stays inside the card', (tester) async {
    final previews = _Scripted()
      ..ready(
        title: 'A very long title that will not fit on one line of the card',
        description:
            'A description long enough to want far more than the two lines '
            'the card gives it, at any size of text, on any screen at all.',
        image: _Pending(),
      );
    await _pump(tester, previews, column: 320, textScale: 2);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(card).height, 88);
  });

  testWidgets('a row whose link changes shows the new link\'s preview', (
    tester,
  ) async {
    final other = Uri.parse('https://loaf.moe/proof');
    final previews = _PerLink()..ready(_link, 'Bake day');
    await _pump(tester, previews);
    expect(find.text('Bake day'), findsOneWidget);

    await _pump(tester, previews, link: other);
    expect(card, findsNothing);
    previews.ready(_link, 'Bake day, again');
    await tester.pump();
    expect(card, findsNothing, reason: 'the old link no longer speaks here');

    previews.ready(other, 'Proofing');
    await tester.pump();
    expect(find.text('Proofing'), findsOneWidget);
  });

  group('on a computer', () {
    Finder ring() => find.descendant(
      of: card,
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border?.top.width == 2,
      ),
    );

    List<Uri> capture() {
      final opened = <Uri>[];
      final real = openMessageLink;
      openMessageLink = (url) async {
        opened.add(url);
        return true;
      };
      addTearDown(() => openMessageLink = real);
      return opened;
    }

    testWidgets('a clicked card is ringed, and Enter opens it again', (
      tester,
    ) async {
      final opened = capture();
      final previews = _Scripted()..ready();
      await _pump(tester, previews);
      expect(ring(), findsNothing);
      await tester.tap(card);
      await tester.pump();
      expect(ring(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(opened, [_link, _link]);
    }, variant: desktop);

    testWidgets('the ring does not follow a card to a new link', (
      tester,
    ) async {
      capture();
      final other = Uri.parse('https://loaf.moe/proof');
      final previews = _PerLink()..ready(_link, 'Bake day');
      await _pump(tester, previews);
      await tester.tap(card);
      await tester.pump();
      await _pump(tester, previews, link: other);
      previews.ready(other, 'Proofing');
      await tester.pump();
      expect(card, findsOneWidget);
      expect(ring(), findsNothing);
    }, variant: desktop);
  });

  testWidgets('a row drawn again does not ask again', (tester) async {
    final previews = _Scripted();
    await _pump(tester, previews);
    await _pump(tester, previews, column: 500);
    expect(previews.asked, [_link]);
  });
}
