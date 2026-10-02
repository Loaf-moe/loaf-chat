import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_media/loaf_media.dart';
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

    testWidgets('on a computer, space opens the clicked media', (tester) async {
      await on(TargetPlatform.macOS, () async {
        var opened = 0;
        await _pump(tester, MediaRow(media: _pdf, onOpen: () => opened++));
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        expect(opened, 0, reason: 'nothing focused yet');

        await tester.tap(find.byType(MediaRow));
        await tester.pump();
        expect(opened, 1);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        expect(opened, 2);
      });
    });
  });

  group('video in place', () {
    const media = MethodChannel('moe.loaf.chat/media');
    final mediaCalls = <MethodCall>[];
    final created = <Map<Object?, Object?>>[];

    // The native ends: the plugin's channel, and the platform views.
    void mockNative(WidgetTester tester) {
      mediaCalls.clear();
      created.clear();
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(media, (call) async {
        mediaCalls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') {
          created.add(call.arguments as Map<Object?, Object?>);
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(media, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      });
    }

    Map<Object?, Object?> paramsOf(Map<Object?, Object?> create) =>
        const StandardMessageCodec().decodeMessage(
          ByteData.sublistView(create['params']! as Uint8List),
        ) as Map<Object?, Object?>;

    testWidgets("tapping a video's play swaps in the player", (tester) async {
      await on(TargetPlatform.macOS, () async {
        mockNative(tester);
        var opened = 0;
        await _pump(tester, MediaRow(media: _video, onOpen: () => opened++));
        expect(find.byType(LoafVideo), findsNothing);

        await tester.tap(find.byType(MediaRow));
        await tester.pump();
        await tester.pump();
        expect(opened, 0, reason: 'it plays here rather than opening');
        expect(find.byType(LoafVideo), findsOneWidget);
        expect(sizeOfRow(tester), const Size(400, 225));
        expect(created, hasLength(1));
        expect(created.single['viewType'], 'moe.loaf.chat/video');
        expect(paramsOf(created.single), {
          'id': 'proof.mp4',
          'mime': 'video/mp4',
        });
        expect(mediaCalls.first.method, 'stream.begin');
        // Nothing has arrived yet: the row says it is coming.
        expect(find.byType(CircularProgressIndicator), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        expect(mediaCalls.last.method, 'stream.end');
      });
    });

    testWidgets('playing a second video pauses the first', (tester) async {
      await on(TargetPlatform.macOS, () async {
        mockNative(tester);
        const other = Media(
          kind: MediaKind.video,
          name: 'crumb.mp4',
          mimeType: 'video/mp4',
          dimensions: Size(640, 360),
          ref: 'assets/mock/media/oven.jpg',
        );
        await _pump(
          tester,
          Column(
            children: [
              MediaRow(media: _video, onOpen: () {}),
              MediaRow(media: other, onOpen: () {}),
            ],
          ),
        );
        await tester.tap(find.byType(MediaRow).first);
        await tester.tap(find.byType(MediaRow).last);
        await tester.pump();
        await tester.pump();
        expect(created, hasLength(2));
        final first = created[0]['id']! as int;
        final second = created[1]['id']! as int;

        Future<void> playing(int view) =>
            tester.binding.defaultBinaryMessenger.handlePlatformMessage(
              media.name,
              const StandardMethodCodec().encodeMethodCall(
                MethodCall('video.playing', {'view': view}),
              ),
              (_) {},
            );

        await playing(first);
        await tester.pump();
        expect(videoFocus.value, first);
        expect(mediaCalls.where((c) => c.method == 'video.pause'), isEmpty);

        await playing(second);
        await tester.pump();
        expect(videoFocus.value, second);
        final pauses = mediaCalls.where((c) => c.method == 'video.pause');
        expect(pauses.map((c) => c.arguments), [
          {'view': first},
        ]);

        await tester.pumpWidget(const SizedBox());
        expect(videoFocus.value, isNull, reason: 'the player is gone');
      });
    });

    testWidgets('scrolling a playing video away pauses it', (tester) async {
      await on(TargetPlatform.macOS, () async {
        mockNative(tester);
        await _pump(
          tester,
          SizedBox(
            height: 600,
            child: ListView(
              children: [
                MediaRow(media: _video, onOpen: () {}),
                const SizedBox(height: 2000),
              ],
            ),
          ),
        );
        await tester.tap(find.byType(MediaRow));
        await tester.pump();
        await tester.pump();
        final view = created.single['id']! as int;
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          media.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('video.playing', {'view': view}),
          ),
          (_) {},
        );

        // Partly out of view still plays.
        await tester.drag(find.byType(ListView), const Offset(0, -150));
        await tester.pump();
        expect(mediaCalls.where((c) => c.method == 'video.pause'), isEmpty);

        await tester.drag(find.byType(ListView), const Offset(0, -200));
        await tester.pump();
        expect(
          mediaCalls
              .where((c) => c.method == 'video.pause')
              .map((c) => c.arguments),
          [
            {'view': view},
          ],
        );
        expect(videoFocus.value, isNull);
      });
    });

    Future<void> nativeSays(
      WidgetTester tester,
      String method,
      Map<String, Object?> arguments,
    ) => tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      media.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, arguments),
      ),
      (_) {},
    );

    Future<_ManualFile> pumpManual(
      WidgetTester tester, {
      VoidCallback? onOpen,
      double height = 600,
    }) async {
      final source = _ManualSource();
      await tester.pumpWidget(
        MaterialApp(
          theme: loafDarkTheme(),
          home: MediaSourceScope(
            source: source,
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  height: height,
                  child: ListView(
                    children: [
                      MediaRow(media: _video, onOpen: onOpen ?? () {}),
                      const SizedBox(height: 2000),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(MediaRow));
      await tester.pump();
      await tester.pump();
      return source.file;
    }

    double? ring(WidgetTester tester) => tester
        .widget<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator),
        )
        .value;

    testWidgets('the download shows until the player is ready', (tester) async {
      await on(TargetPlatform.macOS, () async {
        mockNative(tester);
        final file = await pumpManual(tester);
        expect(file.held, 1, reason: 'the player holds what it reads');
        expect(ring(tester), 0);

        // Past the first bytes, still not playable (an index at the end).
        file.arrive(250);
        await tester.pump();
        expect(ring(tester), 0.25);
        expect(
          find.ancestor(
            of: find.byType(CircularProgressIndicator),
            matching: find.byType(IgnorePointer),
          ),
          findsWidgets,
        );

        await nativeSays(tester, 'video.ready', {'view': created.single['id']});
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(LoafVideo), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        expect(file.held, 0);
      });
    });

    testWidgets("a video the player can't play offers to open it", (
      tester,
    ) async {
      await on(TargetPlatform.macOS, () async {
        mockNative(tester);
        var opened = 0;
        await pumpManual(tester, onOpen: () => opened++);
        await nativeSays(tester, 'video.failed', {
          'view': created.single['id'],
        });
        await tester.pump();
        expect(find.textContaining("couldn't play this"), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.tap(find.text('open it instead'));
        expect(opened, 1);
      });
    });

    testWidgets('in picture in picture, scrolling away leaves it playing', (
      tester,
    ) async {
      await on(TargetPlatform.macOS, () async {
        mockNative(tester);
        final file = await pumpManual(tester);
        final view = created.single['id']! as int;
        await nativeSays(tester, 'video.ready', {'view': view});
        await nativeSays(tester, 'video.playing', {'view': view});
        await nativeSays(tester, 'video.pip', {'view': view, 'active': true});

        await tester.drag(find.byType(ListView), const Offset(0, -400));
        await tester.pump();
        expect(mediaCalls.where((c) => c.method == 'video.pause'), isEmpty);

        // The row goes; the floating player still reads its file.
        await tester.pumpWidget(const SizedBox());
        expect(mediaCalls.where((c) => c.method == 'stream.end'), isEmpty);
        expect(file.held, 1);

        await nativeSays(tester, 'video.pip', {'view': view, 'active': false});
        expect(mediaCalls.last.method, 'stream.end');
        expect(file.held, 0);
        expect(videoFocus.value, isNull);
      });
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

/// A video whose download the test drives.
class _ManualFile extends ChangeNotifier implements MediaFile {
  var held = 0;
  var _received = 0;

  void arrive(int bytes) {
    _received = bytes;
    notifyListeners();
  }

  @override
  String get id => 'manual.mp4';
  @override
  String get partialPath => '/nowhere/manual.mp4.part';
  @override
  int get received => _received;
  @override
  int? get total => 1000;
  @override
  bool get complete => false;
  @override
  Object? get error => null;
  @override
  Future<String> get path => Completer<String>().future;
  @override
  void retry() {}
  @override
  void hold() => held++;
  @override
  void release() => held--;
}

class _ManualSource extends NoMediaSource {
  final file = _ManualFile();

  @override
  MediaFile open(Media media) => file;
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
