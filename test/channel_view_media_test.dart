import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_media/loaf_media.dart';
import 'package:loaf_native/ui/channel/channel_view.dart';
import 'package:loaf_native/ui/channel/media_row.dart';
import 'package:loaf_native/ui/channel/message_group_tile.dart';
import 'package:loaf_native/ui/channel/timeline.dart';
import 'package:loaf_native/ui/model/media_source.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _you = Member('@you', 'you', Colors.red);
const _them = Member('@them', 'them', Colors.blue);
const _ada = Member('@ada', 'ada', Colors.green);

const _proof = Media(
  kind: MediaKind.video,
  name: 'proof.mp4',
  mimeType: 'video/mp4',
  dimensions: Size(640, 360),
  ref: 'proof',
);
const _crumb = Media(
  kind: MediaKind.video,
  name: 'crumb.mp4',
  mimeType: 'video/mp4',
  dimensions: Size(640, 360),
  ref: 'crumb',
);
const _oven = Media(
  kind: MediaKind.image,
  name: 'oven.jpg',
  mimeType: 'image/jpeg',
  dimensions: Size(1600, 1200),
  ref: 'oven',
);
const _rye = Media(
  kind: MediaKind.image,
  name: 'rye.jpg',
  mimeType: 'image/jpeg',
  dimensions: Size(1600, 1200),
  ref: 'rye',
);

class _Timeline extends ChangeNotifier with ComposerAiming implements Timeline {
  _Timeline(this.messages);

  @override
  final Member you = _you;
  @override
  List<Message> messages;
  @override
  bool get writable => true;
  @override
  bool get canLoadOlder => false;
  @override
  bool get loadingOlder => false;
  @override
  bool get loadOlderFailed => false;
  @override
  Stream<String> get failures => const Stream.empty();

  void arrive(Message message) {
    messages = [...messages, message];
    notifyListeners();
  }

  @override
  void loadOlder() {}
  @override
  void send(String text, {List<Mention> mentions = const []}) {}
  @override
  Future<int?> uploadLimit() async => null;

  @override
  void sendFile(Attachment file) {}
  @override
  void toggleReaction(String messageId, String emoji) {}
  @override
  void saveEdit(
    String messageId,
    String text, {
    List<Mention> mentions = const [],
  }) {}
  @override
  void delete(String messageId) {}
  @override
  void retry(String messageId) {}
  @override
  void discard(String messageId) {}
}

/// A download that never moves: the player is what is under test.
class _File extends ChangeNotifier implements MediaFile {
  _File(this.id);

  @override
  final String id;
  @override
  String get partialPath => '/nowhere/$id.part';
  @override
  int get received => 0;
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
  void hold() {}
  @override
  void release() {}
}

class _Source extends NoMediaSource {
  final files = <String, _File>{};

  @override
  MediaFile open(Media media) =>
      files.putIfAbsent(media.name, () => _File(media.name));
}

Message _msg(
  String id,
  Member author, {
  Media? media,
  String body = '',
  int minute = 0,
}) => Message(
  id: id,
  author: author,
  sentAt: DateTime(2026, 9, 27, 10, minute),
  body: body,
  media: media,
);

void main() {
  const channel = MethodChannel('moe.loaf.chat/media');
  final calls = <MethodCall>[];
  final created = <int>[];

  void mockNative(WidgetTester tester) {
    calls.clear();
    created.clear();
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        created.add((call.arguments as Map)['id'] as int);
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    });
  }

  Future<_Timeline> pump(WidgetTester tester, List<Message> messages) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final timeline = _Timeline(messages);
    addTearDown(timeline.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: MediaSourceScope(
          source: _Source(),
          child: Scaffold(
            body: ChannelView(
              channel: const Channel(
                id: '!room',
                name: 'bakery',
                kind: ChannelKind.room,
              ),
              timeline: timeline,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return timeline;
  }

  Finder tileOf(String firstId) => find.byWidgetPredicate(
    (w) => w is MessageGroupTile && w.group.messages.first.id == firstId,
  );

  Finder videoIn(String firstId) =>
      find.descendant(of: tileOf(firstId), matching: find.byType(LoafVideo));

  Future<void> play(WidgetTester tester, String firstId) async {
    await tester.tap(
      find.descendant(of: tileOf(firstId), matching: find.byType(MediaRow)),
    );
    await tester.pump();
    await tester.pump();
  }

  Iterable<String> methods() => calls.map((c) => c.method);

  final desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

  group('a playing video keeps playing when someone else posts', () {
    testWidgets('a text message', variant: desktop, (tester) async {
      mockNative(tester);
      final timeline = await pump(tester, [_msg('1', _them, media: _proof)]);
      await play(tester, '1');
      expect(videoIn('1'), findsOneWidget);
      expect(created, hasLength(1));

      timeline.arrive(_msg('2', _ada, body: 'nice crumb', minute: 1));
      await tester.pump();
      await tester.pump();
      expect(find.text('nice crumb'), findsOneWidget);
      expect(videoIn('1'), findsOneWidget);
      expect(tester.widget<LoafVideo>(videoIn('1')).file.id, 'proof.mp4');
      expect(created, hasLength(1), reason: 'the same player, not a new one');
      expect(methods(), isNot(contains('stream.end')));
    });

    testWidgets('a video', variant: desktop, (tester) async {
      mockNative(tester);
      final timeline = await pump(tester, [_msg('1', _them, media: _proof)]);
      await play(tester, '1');

      timeline.arrive(_msg('2', _ada, media: _crumb, minute: 1));
      await tester.pump();
      await tester.pump();
      expect(videoIn('1'), findsOneWidget);
      expect(tester.widget<LoafVideo>(videoIn('1')).file.id, 'proof.mp4');
      expect(videoIn('2'), findsNothing, reason: 'nobody pressed play on it');
      expect(created, hasLength(1));
      expect(methods(), isNot(contains('stream.end')));
    });
  });

  testWidgets("a row's state follows its message", variant: desktop, (
    tester,
  ) async {
    final timeline = await pump(tester, [_msg('1', _them, media: _oven)]);
    Finder rowIn(String id) =>
        find.descendant(of: tileOf(id), matching: find.byType(MediaRow));
    final before = tester.state(rowIn('1'));

    timeline.arrive(_msg('2', _ada, media: _rye, minute: 1));
    await tester.pump();
    expect(tester.state(rowIn('1')), same(before));
    expect(tester.widget<MediaRow>(rowIn('1')).media.name, 'oven.jpg');
    expect(tester.state(rowIn('2')), isNot(same(before)));
  });
}
