import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/media_row.dart';
import 'package:loaf_native/ui/channel/message_group_tile.dart';
import 'package:loaf_native/ui/channel/message_text.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/mock/mock_media_source.dart';
import 'package:loaf_native/ui/model/media_source.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

const _oven = Media(
  kind: MediaKind.image,
  name: 'oven.jpg',
  mimeType: 'image/jpeg',
  dimensions: Size(1600, 1200),
  size: 214000,
  hasPreview: true,
  ref: 'assets/mock/media/oven.jpg',
);
const _tall = Media(
  kind: MediaKind.image,
  name: 'tall.jpg',
  mimeType: 'image/jpeg',
  dimensions: Size(900, 1600),
  hasPreview: true,
  ref: 'assets/mock/media/tall.jpg',
);
const _video = Media(
  kind: MediaKind.video,
  name: 'proof.mp4',
  mimeType: 'video/mp4',
  dimensions: Size(640, 360),
  duration: Duration(seconds: 4),
  ref: 'assets/mock/media/proof.mp4',
);
const _pdf = Media(
  kind: MediaKind.file,
  name: 'recipe.pdf',
  mimeType: 'application/pdf',
  size: 612,
  ref: 'assets/mock/media/recipe.pdf',
);

Future<void> _pump(
  WidgetTester tester,
  Widget row, {
  double column = 400,
}) async {
  final root = Directory.systemTemp.createTempSync('loaf-media-row-test');
  addTearDown(() => root.deleteSync(recursive: true));
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: MediaSourceScope(
        source: MockMediaSource(root),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: column, child: row),
          ),
        ),
      ),
    ),
  );
}

void main() {
  // The test pins its own platform; the host's must not leak in.
  // It has to be undone before the test ends, so a tearDown is too late.
  Future<void> on(TargetPlatform p, Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = p;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Size sizeOfRow(WidgetTester tester) =>
      tester.getSize(find.byKey(MediaRow.pictureKey));

  group('MediaRow', () {
    testWidgets('an image row is sized from its dimensions before it loads', (
      tester,
    ) async {
      await on(TargetPlatform.macOS, () async {
        await _pump(tester, const MediaRow(media: _oven));
        expect(sizeOfRow(tester), const Size(400, 300));
      });
    });

    testWidgets('a tall image stops at 360', (tester) async {
      await on(TargetPlatform.macOS, () async {
        await _pump(tester, const MediaRow(media: _tall));
        expect(sizeOfRow(tester), const Size(202.5, 360));
      });
    });

    testWidgets('on a phone an image fills the column', (tester) async {
      await on(TargetPlatform.iOS, () async {
        await _pump(tester, const MediaRow(media: _oven), column: 300);
        expect(sizeOfRow(tester).width, 300);
      });
    });

    testWidgets('a video shows its duration and a play badge', (tester) async {
      await _pump(tester, const MediaRow(media: _video));
      expect(find.text('0:04'), findsOneWidget);
      expect(find.byIcon(LucideIcons.play), findsOneWidget);
    });

    testWidgets('a file row names the file and its size', (tester) async {
      await _pump(tester, const MediaRow(media: _pdf));
      expect(find.text('recipe.pdf'), findsOneWidget);
      expect(find.text('612 B'), findsOneWidget);
    });

    testWidgets(
      'a caption is drawn under the media, and a bare file has none',
      (tester) async {
        final author = const Member('@a', 'ada', Colors.red);
        Widget tile(String body) => MessageGroupTile(
          group: MessageGroup([
            Message(
              id: '1',
              author: author,
              sentAt: DateTime(2026, 9, 24, 10),
              body: body,
              media: _pdf,
            ),
          ]),
        );
        await _pump(tester, tile('the recipe'));
        expect(find.byType(MessageText), findsOneWidget);
        expect(find.text('the recipe'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('the recipe')).dy,
          greaterThan(tester.getBottomLeft(find.byType(MediaRow)).dy - 1),
        );

        await _pump(tester, tile(''));
        expect(find.byType(MediaRow), findsOneWidget);
        expect(find.byType(MessageText), findsNothing);
      },
    );

    testWidgets('an uploading row says how far', (tester) async {
      await _pump(tester, const MediaRow(media: _pdf, uploaded: 0.42));
      expect(find.text('uploading 42%'), findsOneWidget);
    });

    testWidgets('with no onOpen the row is not a button', (tester) async {
      await _pump(tester, const MediaRow(media: _pdf));
      expect(find.byType(InkWell), findsNothing);
      final taps = tester
          .widgetList<GestureDetector>(
            find.descendant(
              of: find.byType(MediaRow),
              matching: find.byType(GestureDetector),
            ),
          )
          .where((g) => g.onTap != null);
      expect(taps, isEmpty);
    });

    testWidgets('with onOpen the row opens', (tester) async {
      var opened = 0;
      await _pump(tester, MediaRow(media: _pdf, onOpen: () => opened++));
      await tester.tap(find.byType(MediaRow));
      expect(opened, 1);
    });
  });

  group('a preview that will not load', () {
    // Counts the loads, and fails every one.
    final loads = <int>[];

    Future<void> pumpFailing(
      WidgetTester tester, {
      VoidCallback? onRetry,
    }) async {
      loads.clear();
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: MediaSourceScope(
            source: _FailingSource(loads),
            child: Scaffold(
              body: MediaRow(media: _oven, onOpen: () {}, onRetry: onRetry),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('says so, and offers to try again', (tester) async {
      var retried = 0;
      await pumpFailing(tester, onRetry: () => retried++);
      expect(find.textContaining("couldn't load"), findsOneWidget);
      expect(loads, hasLength(1));
      await tester.tap(find.text('try again'));
      await tester.pumpAndSettle();
      expect(retried, 1);
      expect(loads, hasLength(2));
    });

    testWidgets('with nothing to retry, draws no "try again"', (tester) async {
      await pumpFailing(tester);
      expect(find.text("couldn't load"), findsOneWidget);
      expect(find.text('try again'), findsNothing);
    });
  });

  group('quoteOf', () {
    Message of(Media media, {String body = ''}) => Message(
      id: '1',
      author: const Member('@a', 'ada', Colors.red),
      sentAt: DateTime(2026),
      body: body,
      media: media,
    );

    test('the caption wins', () {
      expect(quoteOf(of(_oven, body: 'first bake')), 'first bake');
    });

    test('kinds without words get a lowercase label', () {
      expect(quoteOf(of(_oven)), 'photo');
      expect(
        quoteOf(
          of(
            const Media(
              kind: MediaKind.image,
              name: 'crumb.gif',
              mimeType: 'image/gif',
              ref: 'x',
            ),
          ),
        ),
        'gif',
      );
      expect(quoteOf(of(_video)), 'video');
      expect(
        quoteOf(
          of(const Media(kind: MediaKind.audio, name: 'a.m4a', ref: 'x')),
        ),
        'audio',
      );
    });

    test('a file is its name', () {
      expect(quoteOf(of(_pdf)), 'recipe.pdf');
    });
  });
}

class _FailingSource extends NoMediaSource {
  const _FailingSource(this.loads);
  final List<int> loads;

  @override
  ImageProvider? preview(Media media, double physicalWidth) =>
      _FailingImage(loads);
}

class _FailingImage extends ImageProvider<_FailingImage> {
  _FailingImage(this.loads);
  final List<int> loads;

  @override
  Future<_FailingImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _FailingImage key,
    ImageDecoderCallback decode,
  ) {
    loads.add(loads.length);
    return OneFrameImageStreamCompleter(Future.error(StateError('no')));
  }

  // One key, so a retry has to evict it to load again.
  @override
  bool operator ==(Object other) => other is _FailingImage;

  @override
  int get hashCode => 1;
}
