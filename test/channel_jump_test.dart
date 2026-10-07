import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/channel_view.dart';
import 'package:loaf_native/ui/channel/timeline_controller.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

const _you = Member('@you', 'you', Colors.red);
const _ada = Member('@ada', 'Ada', Colors.blue);
const _bo = Member('@bo', 'Bo', Colors.green);
const _channel = Channel(id: '!room', name: 'bakery', kind: ChannelKind.room);

/// Messages [from] to [to], each in its own group: authors alternate.
List<Message> _messages(int from, int to, {Map<int, int> replies = const {}}) =>
    [
      for (var i = from; i <= to; i++)
        Message(
          id: 'm$i',
          author: i.isEven ? _ada : _bo,
          sentAt: DateTime(2026, 10, 6, 9).add(Duration(minutes: i)),
          body: 'message $i',
          replyTo: replies[i] == null
              ? null
              : Message(
                  id: 'm${replies[i]}',
                  author: replies[i]!.isEven ? _ada : _bo,
                  sentAt: DateTime(2026, 10, 6, 9),
                  body: 'message ${replies[i]}',
                ),
        ),
    ];

/// The mock timeline with pages newer than what it has loaded, as one
/// opened back in history would.
class _Paged extends TimelineController {
  _Paged(super.messages, this._pages) : super(you: _you);

  final List<List<Message>> _pages;
  final _landed = <Message>[];
  var newerAsked = 0;
  var _stretch = 0;
  String? _forced;

  @override
  List<Message> get messages => [...super.messages, ..._landed];
  @override
  bool get canLoadNewer => _pages.isNotEmpty;
  @override
  void loadNewer() {
    newerAsked++;
    if (_pages.isEmpty) return;
    _landed.addAll(_pages.removeAt(0));
    notifyListeners();
  }

  @override
  int get stretch => _stretch;
  void reopen() {
    _stretch++;
    notifyListeners();
  }

  /// What a jump that reopens the conversation does: one notify carrying
  /// both the new stretch and the target.
  void reopenAt(String id) {
    _stretch++;
    _forced = id;
    notifyListeners();
  }

  /// A message arriving live, once nothing newer is left to page in.
  void arrive(Message message) {
    assert(!canLoadNewer);
    _landed.add(message);
    notifyListeners();
  }

  /// A target that draws no row, as a deleted message would.
  void forceTarget(String id) {
    _forced = id;
    notifyListeners();
  }

  @override
  String? get jumpTarget => _forced ?? super.jumpTarget;
  @override
  void jumpShown() {
    _forced = null;
    super.jumpShown();
  }
}

Future<void> _pump(
  WidgetTester tester,
  TimelineController timeline, {
  VoidCallback? onRead,
}) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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
}

Rect get _viewport => _tester.getRect(find.byType(CustomScrollView));
late WidgetTester _tester;

bool _onScreen(String text) {
  final found = find.text(text);
  if (found.evaluate().isEmpty) return false;
  return _viewport.overlaps(_tester.getRect(found));
}

double _glow() {
  final glow = _tester.widget<AnimatedContainer>(
    find.byKey(const ValueKey('jump-glow')),
  );
  return (glow.decoration! as BoxDecoration).color!.a;
}

void main() {
  testWidgets('a jump brings an old message into view and lights it', (
    tester,
  ) async {
    _tester = tester;
    final timeline = TimelineController(_messages(0, 119), you: _you);
    await _pump(tester, timeline);
    expect(_onScreen('message 10'), isFalse);

    timeline.jumpTo('m10');
    await tester.pumpAndSettle();
    expect(_onScreen('message 10'), isTrue);
    expect(timeline.jumpTarget, isNull); // Shown, so let go.
    expect(_glow(), greaterThan(0));

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(_glow(), 0);
  });

  testWidgets('jumping to the same message twice lights it twice', (
    tester,
  ) async {
    _tester = tester;
    final timeline = TimelineController(_messages(0, 119), you: _you);
    await _pump(tester, timeline);
    timeline.jumpTo('m10');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(_glow(), 0);

    timeline.jumpTo('m10');
    await tester.pumpAndSettle();
    expect(_glow(), greaterThan(0));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a target that draws no row says it is unavailable', (
    tester,
  ) async {
    _tester = tester;
    final timeline = _Paged(_messages(0, 30), const []);
    await _pump(tester, timeline);
    timeline.forceTarget('deleted');
    await tester.pumpAndSettle();
    expect(timeline.jumpTarget, isNull);
    expect(find.text(messageUnavailable), findsOneWidget);
    expect(find.byKey(const ValueKey('jump-glow')), findsNothing);
    expect(_onScreen('message 30'), isTrue);
  });

  testWidgets('scrolling down to the live end marks the room read', (
    tester,
  ) async {
    _tester = tester;
    final timeline = _Paged(_messages(0, 39), [_messages(40, 59)]);
    var read = 0;
    await _pump(tester, timeline, onRead: () => read++);
    timeline.jumpTo('m10');
    await tester.pumpAndSettle();

    // Near the newest loaded message, the next page loads by itself.
    for (var i = 0; i < 40 && timeline.canLoadNewer; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
    }
    expect(timeline.canLoadNewer, isFalse);
    expect(read, 1);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a message that is not there says so', (tester) async {
    _tester = tester;
    final timeline = TimelineController(_messages(0, 5), you: _you);
    await _pump(tester, timeline);
    timeline.jumpTo('nope');
    await tester.pumpAndSettle();
    expect(find.text(messageUnavailable), findsOneWidget);
  });

  testWidgets('a newer page landing leaves what you are reading in place', (
    tester,
  ) async {
    _tester = tester;
    final timeline = _Paged(_messages(0, 39), [_messages(40, 59)]);
    await _pump(tester, timeline);
    timeline.jumpTo('m10');
    await tester.pumpAndSettle();
    final before = tester.getRect(find.text('message 10')).top;

    timeline.loadNewer();
    await tester.pumpAndSettle();
    expect(timeline.messages.any((m) => m.id == 'm40'), isTrue);
    expect(tester.getRect(find.text('message 10')).top, before);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('scrolling down from there loads forward to the live end', (
    tester,
  ) async {
    _tester = tester;
    final timeline = _Paged(_messages(0, 39), [
      _messages(40, 59),
      _messages(60, 79),
    ]);
    await _pump(tester, timeline);
    timeline.jumpTo('m10');
    await tester.pumpAndSettle();

    for (var i = 0; i < 40 && !_onScreen('message 79'); i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
    }
    expect(timeline.canLoadNewer, isFalse);
    expect(_onScreen('message 79'), isTrue);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a failed newer page offers to try again', (tester) async {
    _tester = tester;
    final timeline = _FailingNewer(_messages(0, 39));
    await _pump(tester, timeline);
    expect(find.text("couldn't load newer messages · "), findsOneWidget);
    expect(_onScreen("couldn't load newer messages · "), isTrue);
    await tester.tap(find.text('try again'));
    await tester.pumpAndSettle();
    expect(timeline.retried, 1);
  });

  testWidgets('a target high in a tall group is scrolled to', (tester) async {
    _tester = tester;
    final timeline = TimelineController([
      for (var i = 0; i < 60; i++)
        Message(
          id: 'm$i',
          author: _ada,
          sentAt: DateTime(2026, 10, 6, 9).add(Duration(minutes: i)),
          body: 'message $i',
        ),
    ], you: _you);
    await _pump(tester, timeline);
    timeline.jumpTo('m2');
    await tester.pumpAndSettle();
    expect(_onScreen('message 2'), isTrue);
    expect(_glow(), greaterThan(0));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a jump that reopens the conversation still lands', (
    tester,
  ) async {
    _tester = tester;
    final timeline = _Paged(_messages(0, 119), const []);
    await _pump(tester, timeline);
    timeline.reopenAt('m10');
    await tester.pumpAndSettle();
    expect(_onScreen('message 10'), isTrue);
    expect(_glow(), greaterThan(0));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a live message after a jump stays in view at the newest end', (
    tester,
  ) async {
    _tester = tester;
    final timeline = _Paged(_messages(0, 39), [_messages(40, 59)]);
    await _pump(tester, timeline);
    timeline.jumpTo('m10');
    await tester.pumpAndSettle();
    for (var i = 0; i < 40 && !_onScreen('message 59'); i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
    }
    expect(_onScreen('message 59'), isTrue);
    await tester.pump(const Duration(seconds: 2));

    timeline.arrive(_messages(60, 60).single);
    await tester.pumpAndSettle();
    expect(_onScreen('message 60'), isTrue);
  });

  testWidgets('a new stretch starts the list over, at its newest', (
    tester,
  ) async {
    _tester = tester;
    final timeline = _Paged(_messages(0, 119), const []);
    await _pump(tester, timeline);
    timeline.jumpTo('m10');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(_onScreen('message 119'), isFalse);

    timeline.reopen();
    await tester.pumpAndSettle();
    expect(_onScreen('message 119'), isTrue);
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
    testWidgets(
      "tapping a reply's quote jumps to what it answers",
      variant: TargetPlatformVariant.only(platform),
      (tester) async {
        _tester = tester;
        final timeline = TimelineController(
          _messages(0, 59, replies: {59: 5}),
          you: _you,
        );
        await _pump(tester, timeline);
        expect(_onScreen('message 5'), isFalse);

        await tester.tap(
          find.textContaining('  message 5', findRichText: true),
        );
        await tester.pumpAndSettle();
        expect(_onScreen('message 5'), isTrue);
        expect(_glow(), greaterThan(0));
        await tester.pump(const Duration(seconds: 2));
      },
    );
  }
}

/// Short of live, and its last newer page failed.
class _FailingNewer extends TimelineController {
  _FailingNewer(super.messages) : super(you: _you);
  var retried = 0;
  // Live again once the retry has gone through.
  @override
  bool get canLoadNewer => retried == 0;
  @override
  bool get loadNewerFailed => retried == 0;
  @override
  void loadNewer() {
    retried++;
    notifyListeners();
  }
}
