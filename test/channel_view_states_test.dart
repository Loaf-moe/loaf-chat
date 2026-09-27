import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/channel_view.dart';
import 'package:loaf_native/ui/channel/composer.dart';
import 'package:loaf_native/ui/channel/timeline.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _you = Member('@you', 'you', Colors.red);
const _them = Member('@them', 'them', Colors.blue);

/// A timeline whose every state the test sets by hand, and which records
/// what it was asked to do.
class _FakeTimeline extends ChangeNotifier
    with ComposerAiming
    implements Timeline {
  _FakeTimeline(this.messages);

  @override
  final Member you = _you;
  @override
  List<Message> messages;
  @override
  bool writable = true;
  @override
  bool canLoadOlder = false;
  @override
  bool loadingOlder = false;
  @override
  bool loadOlderFailed = false;

  final failuresController = StreamController<String>.broadcast();
  @override
  Stream<String> get failures => failuresController.stream;

  final calls = <String>[];

  void update() => notifyListeners();

  bool get listening => hasListeners;

  @override
  void loadOlder() => calls.add('loadOlder');
  @override
  void send(String text) => calls.add('send $text');
  @override
  void toggleReaction(String messageId, String emoji) =>
      calls.add('react $messageId $emoji');
  @override
  void saveEdit(String messageId, String text) =>
      calls.add('edit $messageId $text');
  @override
  void delete(String messageId) => calls.add('delete $messageId');
  @override
  void retry(String messageId) => calls.add('retry $messageId');
  @override
  void discard(String messageId) => calls.add('discard $messageId');

  @override
  void dispose() {
    unawaited(failuresController.close());
    super.dispose();
  }
}

Message _msg(
  String id, {
  Member author = _them,
  String body = 'hello',
  MessageStatus status = MessageStatus.sent,
  bool locked = false,
  Message? replyTo,
  int minute = 0,
}) => Message(
  id: id,
  author: author,
  sentAt: DateTime(2026, 9, 27, 10, minute),
  body: body,
  status: status,
  locked: locked,
  replyTo: replyTo,
);

const _channel = Channel(id: '!room', name: 'bakery', kind: ChannelKind.room);

Future<_FakeTimeline> _pump(
  WidgetTester tester,
  List<Message> messages, {
  VoidCallback? onRead,
  void Function(_FakeTimeline)? setUp,
}) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final timeline = _FakeTimeline(messages);
  setUp?.call(timeline);
  addTearDown(timeline.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(
        body: ChannelView(
          channel: _channel,
          timeline: timeline,
          onRead: onRead,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return timeline;
}

final _mobile = TargetPlatformVariant.only(TargetPlatform.iOS);
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

void main() {
  group('a message on its way', () {
    testWidgets('is dimmed, and can only be copied', variant: _mobile, (
      tester,
    ) async {
      await _pump(tester, [
        _msg('~1', author: _you, body: 'rising', status: MessageStatus.sending),
      ]);
      final opacity = tester.widget<Opacity>(
        find.ancestor(of: find.text('rising'), matching: find.byType(Opacity)),
      );
      expect(opacity.opacity, 0.5);
      await tester.longPress(find.text('rising'));
      await tester.pumpAndSettle();
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Reply'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(find.text('👍'), findsNothing);
    });

    testWidgets('shows no hover toolbar on a computer', variant: _desktop, (
      tester,
    ) async {
      await _pump(tester, [
        _msg('~1', author: _you, body: 'rising', status: MessageStatus.sending),
      ]);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(find.text('rising')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Reply'), findsNothing);
    });
  });

  group('a message that did not send', () {
    testWidgets('says so, and retries or discards', (tester) async {
      final timeline = await _pump(tester, [
        _msg('~1', author: _you, body: 'rising', status: MessageStatus.failed),
      ]);
      expect(find.text("didn't send"), findsOneWidget);
      await tester.tap(find.text('retry'));
      await tester.tap(find.text('discard'));
      expect(timeline.calls, ['retry ~1', 'discard ~1']);
    });
  });

  testWidgets(
    'a locked message says why, and offers nothing',
    variant: _mobile,
    (tester) async {
      await _pump(tester, [_msg('1', locked: true, body: '')]);
      expect(
        find.text('encrypted · readable once this device is verified'),
        findsOneWidget,
      );
      await tester.longPress(
        find.text('encrypted · readable once this device is verified'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Copy text'), findsNothing);
    },
  );

  testWidgets('a reply to a message not loaded quotes a stub', (tester) async {
    await _pump(tester, [
      _msg(
        '2',
        body: 'agreed',
        replyTo: Message.stub(id: r'$gone', author: _you),
      ),
    ]);
    expect(find.textContaining('a message further up'), findsOneWidget);
  });

  testWidgets('an unwritable room has a note where the composer was', (
    tester,
  ) async {
    await _pump(tester, [_msg('1')], setUp: (t) => t.writable = false);
    expect(find.byType(Composer), findsNothing);
    expect(find.text('sending here waits for encryption'), findsOneWidget);
  });

  group('older messages', () {
    testWidgets('a short conversation asks for more straight away', (
      tester,
    ) async {
      final timeline = await _pump(tester, [
        _msg('1'),
      ], setUp: (t) => t.canLoadOlder = true);
      expect(timeline.calls, contains('loadOlder'));
    });

    testWidgets('loading shows at the top', (tester) async {
      await _pump(tester, [_msg('1')], setUp: (t) => t.loadingOlder = true);
      expect(find.text('loading older messages'), findsOneWidget);
    });

    testWidgets('a failed page offers to try again', (tester) async {
      final timeline = await _pump(tester, [
        _msg('1'),
      ], setUp: (t) => t.loadOlderFailed = true);
      await tester.tap(find.text('try again'));
      expect(timeline.calls, ['loadOlder']);
    });

    testWidgets('a whole conversation asks for nothing', (tester) async {
      final timeline = await _pump(tester, [_msg('1')]);
      expect(timeline.calls, isEmpty);
    });
  });

  testWidgets('an action the server refused is a toast', (tester) async {
    final timeline = await _pump(tester, [_msg('1')]);
    timeline.failuresController.add("couldn't react");
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text("couldn't react"), findsOneWidget);
  });

  group('reading while looking', () {
    testWidgets('someone else\'s new message is read', (tester) async {
      var read = 0;
      final timeline = await _pump(tester, [_msg('1')], onRead: () => read++);
      timeline
        ..messages = [...timeline.messages, _msg('2', minute: 1)]
        ..update();
      await tester.pump();
      expect(read, 1);
    });

    testWidgets('your own is not a reason to mark read', (tester) async {
      var read = 0;
      final timeline = await _pump(tester, [_msg('1')], onRead: () => read++);
      timeline
        ..messages = [...timeline.messages, _msg('2', author: _you)]
        ..update();
      await tester.pump();
      expect(read, 0);
    });

    testWidgets('older messages paging in are not new', (tester) async {
      var read = 0;
      final timeline = await _pump(tester, [_msg('1')], onRead: () => read++);
      timeline
        ..messages = [_msg('0'), ...timeline.messages]
        ..update();
      await tester.pump();
      expect(read, 0);
    });

    testWidgets('nothing is read with the app in the background', (
      tester,
    ) async {
      var read = 0;
      final timeline = await _pump(tester, [_msg('1')], onRead: () => read++);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      timeline
        ..messages = [...timeline.messages, _msg('2', minute: 1)]
        ..update();
      await tester.pump();
      expect(read, 0);
    });
  });

  testWidgets('switching rooms listens to the new room', (tester) async {
    final first = await _pump(tester, [_msg('1', body: 'first room')]);
    final second = _FakeTimeline([_msg('a', body: 'second room')]);
    addTearDown(second.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: loafDarkTheme(),
        home: Scaffold(
          body: ChannelView(channel: _channel, timeline: second),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(first.listening, isFalse);
    second
      ..messages = [...second.messages, _msg('b', body: 'arrived')]
      ..update();
    await tester.pump();
    expect(find.text('arrived'), findsOneWidget);
  });
}
