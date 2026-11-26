import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/channel/pinned_panel.dart';
import 'package:loaf_native/ui/channel/timeline.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

const _you = Member('@you', 'you', Colors.red);
const _ada = Member('@ada', 'Ada Crumb', Colors.purple);

Message _msg(String id, String body, {int minute = 0}) => Message(
  id: id,
  author: _ada,
  sentAt: DateTime(2026, 9, 24, 10, minute),
  body: body,
);

/// A timeline whose pins and fetches the test drives by hand.
class _FakeTimeline extends ChangeNotifier
    with ComposerAiming
    implements Timeline {
  _FakeTimeline(
    this.messages, {
    this.pinnedIds = const [],
    this.canPin = false,
  });

  @override
  final Member you = _you;
  @override
  List<Message> messages;
  @override
  List<String> pinnedIds;
  @override
  bool canPin;

  final calls = <String>[];

  /// Each fetch asked, by id, waiting for the test to answer it.
  final pending = <String, Completer<Message?>>{};
  final fetched = <String>[];

  @override
  Future<Message?> fetch(String id) {
    fetched.add(id);
    final completer = Completer<Message?>();
    pending[id] = completer;
    return completer.future;
  }

  void update() => notifyListeners();

  @override
  void pin(String messageId) => calls.add('pin $messageId');
  @override
  void unpin(String messageId) => calls.add('unpin $messageId');
  @override
  void jumpTo(String messageId) => calls.add('jumpTo $messageId');

  final _failures = StreamController<String>.broadcast();
  @override
  Stream<String> get failures => _failures.stream;
  @override
  bool get writable => true;
  @override
  bool get canLoadOlder => false;
  @override
  bool get loadingOlder => false;
  @override
  bool get loadOlderFailed => false;
  @override
  void loadOlder() {}
  @override
  bool get canLoadNewer => false;
  @override
  bool get loadingNewer => false;
  @override
  bool get loadNewerFailed => false;
  @override
  void loadNewer() {}
  @override
  int get stretch => 0;
  @override
  String? get jumpTarget => null;
  @override
  void jumpShown() {}
  @override
  void showNewest() {}
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

  @override
  void dispose() {
    unawaited(_failures.close());
    super.dispose();
  }
}

final _mobile = TargetPlatformVariant.only(TargetPlatform.iOS);
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

/// A pin button near the top of the window, as the header's is, that opens
/// the list; the list is then open when this returns.
Future<void> _open(WidgetTester tester, _FakeTimeline timeline) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(timeline.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: Builder(
            builder: (context) => IconButton(
              icon: const Icon(LucideIcons.pin),
              onPressed: () {
                final box = context.findRenderObject()! as RenderBox;
                showPinnedPanel(
                  context,
                  timeline,
                  anchor: box.localToGlobal(Offset.zero) & box.size,
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byIcon(LucideIcons.pin));
  await tester.pumpAndSettle();
}

final _title = find.text('pinned messages');

void main() {
  testWidgets('rows read newest pin first', variant: _mobile, (tester) async {
    await _open(
      tester,
      _FakeTimeline(
        [_msg('a', 'first pinned'), _msg('b', 'second pinned', minute: 1)],
        pinnedIds: ['a', 'b'],
      ),
    );
    final second = tester.getTopLeft(find.text('second pinned'));
    final first = tester.getTopLeft(find.text('first pinned'));
    expect(second.dy, lessThan(first.dy));
  });

  testWidgets('a loaded message is drawn without fetching', variant: _mobile, (
    tester,
  ) async {
    final timeline = _FakeTimeline([_msg('a', 'hold this')], pinnedIds: ['a']);
    await _open(tester, timeline);
    expect(find.text('hold this'), findsOneWidget);
    expect(find.text('Ada Crumb'), findsOneWidget);
    expect(find.text('10:00'), findsOneWidget);
    expect(timeline.fetched, isEmpty);
  });

  testWidgets(
    'a message not loaded is fetched, and drawn when it comes',
    variant: _mobile,
    (tester) async {
      final timeline = _FakeTimeline([], pinnedIds: ['old']);
      await _open(tester, timeline);
      expect(find.text('loading…'), findsOneWidget);
      expect(timeline.fetched, ['old']);

      timeline.pending['old']!.complete(_msg('old', 'from long ago'));
      await tester.pumpAndSettle();
      expect(find.text('from long ago'), findsOneWidget);
      expect(find.text('loading…'), findsNothing);
    },
  );

  testWidgets('a message that cannot be had says so', variant: _mobile, (
    tester,
  ) async {
    final timeline = _FakeTimeline([], pinnedIds: ['gone']);
    await _open(tester, timeline);
    timeline.pending['gone']!.complete(null);
    await tester.pumpAndSettle();
    expect(find.text(messageUnavailable), findsOneWidget);
  });

  testWidgets('a fetch that failed offers to try again', variant: _mobile, (
    tester,
  ) async {
    final timeline = _FakeTimeline([], pinnedIds: ['far']);
    await _open(tester, timeline);
    timeline.pending['far']!.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text("couldn't load · try again"), findsOneWidget);

    await tester.tap(find.text("couldn't load · try again"));
    await tester.pumpAndSettle();
    expect(timeline.fetched, ['far', 'far']);
    timeline.pending['far']!.complete(_msg('far', 'there it is'));
    await tester.pumpAndSettle();
    expect(find.text('there it is'), findsOneWidget);
  });

  testWidgets('a tap closes the list and jumps', variant: _mobile, (
    tester,
  ) async {
    final timeline = _FakeTimeline([_msg('a', 'hold this')], pinnedIds: ['a']);
    await _open(tester, timeline);
    await tester.tap(find.text('hold this'));
    await tester.pumpAndSettle();
    expect(_title, findsNothing);
    expect(timeline.calls, ['jumpTo a']);
  });

  testWidgets(
    'unpin is not offered to those who may not pin',
    variant: _mobile,
    (tester) async {
      await _open(
        tester,
        _FakeTimeline([_msg('a', 'hold this')], pinnedIds: ['a']),
      );
      expect(find.byTooltip('Unpin'), findsNothing);
    },
  );

  testWidgets('unpin on a row unpins it', variant: _mobile, (tester) async {
    final timeline = _FakeTimeline(
      [_msg('a', 'hold this')],
      pinnedIds: ['a'],
      canPin: true,
    );
    await _open(tester, timeline);
    await tester.tap(find.byTooltip('Unpin'));
    await tester.pumpAndSettle();
    expect(timeline.calls, ['unpin a']);
    expect(_title, findsOneWidget, reason: 'the list stays open');
  });

  testWidgets(
    'unpin is offered on a message that cannot be had: it clears a dead pin',
    variant: _mobile,
    (tester) async {
      final timeline = _FakeTimeline([], pinnedIds: ['gone'], canPin: true);
      await _open(tester, timeline);
      timeline.pending['gone']!.complete(null);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Unpin'));
      expect(timeline.calls, ['unpin gone']);
    },
  );

  testWidgets('empty says so', variant: _mobile, (tester) async {
    await _open(tester, _FakeTimeline([]));
    expect(find.text('nothing pinned yet'), findsOneWidget);
    expect(find.text('pin a message from its menu'), findsNothing);
  });

  testWidgets('empty tells those who may pin how', variant: _mobile, (
    tester,
  ) async {
    await _open(tester, _FakeTimeline([], canPin: true));
    expect(find.text('pin a message from its menu'), findsOneWidget);
  });

  testWidgets('a pin arriving while open shows', variant: _mobile, (
    tester,
  ) async {
    final timeline = _FakeTimeline([_msg('a', 'hold this')]);
    await _open(tester, timeline);
    expect(find.text('nothing pinned yet'), findsOneWidget);

    timeline.pinnedIds = ['a'];
    timeline.update();
    await tester.pumpAndSettle();
    expect(find.text('hold this'), findsOneWidget);
    expect(find.text('nothing pinned yet'), findsNothing);
  });

  testWidgets('a phone gets a sheet', variant: _mobile, (tester) async {
    await _open(tester, _FakeTimeline([]));
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(_title, findsOneWidget);
  });

  testWidgets('a computer gets a popover under the button', variant: _desktop, (
    tester,
  ) async {
    await _open(tester, _FakeTimeline([]));
    expect(find.byType(BottomSheet), findsNothing);
    expect(_title, findsOneWidget);
    final button = tester.getRect(find.byIcon(LucideIcons.pin).first);
    expect(tester.getTopLeft(_title).dy, greaterThan(button.bottom));
  });
}
