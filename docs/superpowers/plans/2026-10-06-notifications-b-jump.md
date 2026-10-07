# Notifications B — Jump to Message Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `MessageRoute(roomId, eventId)` opens the right space and channel, loads the conversation around that message, scrolls it into view and lights it briefly; scrolling down loads forward to the live end. Tapping a reply's quote does the same within a room.

**Architecture:** The UI's `Timeline` interface grows a jump (`jumpTo`, `jumpTarget`/`jumpShown`), forward paging (`canLoadNewer`, `loadNewer`, …), `showNewest` and a `stretch` counter. `MatrixTimeline` keeps one SDK timeline per room as today, and reopens it with `room.getTimeline(eventContextId:)` when the target isn't loaded; the SDK's fragmented timeline pages forward with `requestFuture` until it is live. The channel view switches from a `ListView` to a `CustomScrollView` whose `center` sliver starts at the jumped-to message, so newer pages grow below it without moving what is on screen. The shell follows routes from a `Stream<MessageRoute>` that steps D and E will feed.

**Tech Stack:** Flutter/Dart, `matrix` 13.0.0 SDK (`Room.getTimeline`, `Timeline.requestFuture`), `flutter_test` with the SDK's `FakeMatrixApi`.

**Spec:** `docs/superpowers/specs/2026-10-06-notifications-design.md` (section "B. Jump to message")

## Global Constraints

- The route selects the room's space (Home for DMs and rooms outside spaces) and opens the channel.
- The timeline loads around the event with `eventContextId`, scrolls it into view, and highlights it briefly. Scrolling down from there loads forward to the live end.
- A route to a room you've left (or never joined) shows the toast and stays where you are. An event the server won't return opens the channel at its newest messages with the toast. (Chris decided this on 2026-10-06; Task 5 amends the spec to match.)
- Toast copy, exactly: `that message isn't available` (the constant `messageUnavailable`).
- The route type is `MessageRoute`, not `Route`: Flutter's `widgets` library exports a `Route`, and every UI file imports it. Task 5 amends the spec, including step D's `Stream<MessageRoute> get clicks`.
- Hand-test entry point: tapping a reply's quote jumps to the message it answers (Chris chose this on 2026-10-06). No mock-only debug lever.
- Client-side only, no new dependencies.
- Run tests with `mise exec -- flutter test <path>`. Analysis: `mise exec -- flutter analyze`. Formatting: `mise exec -- dart format lib test`.
- Comments explain why, in the repo's voice: short declarative sentences, no "we". Match the surrounding code's comment density.
- Baseline: 1445 tests passing on `main` at `7a300d2`.

## Review Focus

1. **Writing while back in history.** A fragmented SDK timeline ignores everything live, so a message sent, or a reaction added, while viewing an old stretch would never appear. Expected: sending returns to the newest messages first; reacting, editing or deleting catches up to live while keeping your place. Pinned by Task 2's "sending while back in history" and "reacting while back in history" tests.
2. **A route before the first sync** (iOS cold start, step E). The room isn't known yet. Expected: the route waits until the rooms are synced, then is followed. It should not toast "isn't available". Pinned by Task 5's "a route before the first sync waits for it".
3. **Two jumps in quick succession** (two notification clicks). Expected: only the last one lands; the slower first reopen must not overwrite it. Pinned by Task 2's "a later jump overtakes an earlier one".
4. **A room in more than one space.** Expected: if the space you're in has it, you stay in that space. Pinned by Task 5's "a room in the space you are in stays there".
5. **A forward page that fails** (offline while scrolling down). The SDK leaves `isRequestingFuture` stuck at true after a throw, so every later page silently does nothing. Expected: a "couldn't load newer messages · try again" line whose retry works. Pinned by Task 2's "a failed newer page can be tried again" and Task 3's newer-line test.

---

### Task 1: The route and the timeline's jump interface

**Files:**
- Create: `lib/ui/model/message_route.dart`
- Modify: `lib/ui/channel/timeline.dart` (the `Timeline` interface, plus a `messageUnavailable` constant)
- Modify: `lib/ui/channel/timeline_controller.dart` (the mock backend's `Timeline`)
- Modify (test fakes that implement `Timeline`, so the suite compiles): `test/channel_view_states_test.dart`, `test/channel_view_encryption_test.dart`, `test/channel_view_media_test.dart`
- Test: `test/timeline_controller_test.dart`, `test/message_route_test.dart`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `class MessageRoute { const MessageRoute(String roomId, String eventId); final String roomId; final String eventId; }` with value equality.
  - `const messageUnavailable = "that message isn't available";` in `timeline.dart`.
  - New `Timeline` members: `bool get canLoadNewer`, `bool get loadingNewer`, `bool get loadNewerFailed`, `void loadNewer()`, `int get stretch`, `String? get jumpTarget`, `void jumpShown()`, `void jumpTo(String messageId)`, `void showNewest()`.
  - `TimelineController`: `jumpTo` sets `jumpTarget` for a loaded message, else adds `messageUnavailable` to `failures`; never has newer messages; `stretch` is always 0; `failures` is a real broadcast stream now, closed in `dispose`.

- [ ] **Step 1: Write the failing tests**

`test/message_route_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/message_route.dart';

void main() {
  test('two routes to the same message are equal', () {
    expect(
      const MessageRoute('!a:x', r'$1'),
      const MessageRoute('!a:x', r'$1'),
    );
    expect(
      const MessageRoute('!a:x', r'$1').hashCode,
      const MessageRoute('!a:x', r'$1').hashCode,
    );
    expect(
      const MessageRoute('!a:x', r'$1'),
      isNot(const MessageRoute('!a:x', r'$2')),
    );
  });
}
```

Append to `test/timeline_controller_test.dart`, inside `main()`:

```dart
  group('jumping', () {
    TimelineController timeline() => TimelineController([
      _msg('1', _them),
      _msg('2', _you),
      _msg('3', _them),
    ], you: _you);

    test('to a loaded message names it as the target, and says so', () {
      final t = timeline();
      addTearDown(t.dispose);
      var heard = 0;
      t.addListener(() => heard++);
      t.jumpTo('2');
      expect(t.jumpTarget, '2');
      expect(heard, 1);
    });

    test('once shown, the target is let go', () {
      final t = timeline()..jumpTo('2');
      addTearDown(t.dispose);
      t.jumpShown();
      expect(t.jumpTarget, isNull);
    });

    test('to a message it does not have says it is not available', () async {
      final t = timeline();
      addTearDown(t.dispose);
      final said = <String>[];
      t.failures.listen(said.add);
      t.jumpTo('nope');
      await Future<void>.delayed(Duration.zero);
      expect(said, [messageUnavailable]);
      expect(t.jumpTarget, isNull);
    });

    test('the mock is always at the live end', () {
      final t = timeline();
      addTearDown(t.dispose);
      expect(t.canLoadNewer, isFalse);
      expect(t.loadingNewer, isFalse);
      expect(t.loadNewerFailed, isFalse);
      expect(t.stretch, 0);
      t.showNewest(); // Nothing to do, and nothing breaks.
    });
  });
```

Add `import 'package:loaf_native/ui/channel/timeline.dart' show messageUnavailable;` to the test's imports.

- [ ] **Step 2: Run them to see them fail**

Run: `mise exec -- flutter test test/message_route_test.dart test/timeline_controller_test.dart`
Expected: compile errors (`MessageRoute`, `jumpTo`, `messageUnavailable` not defined).

- [ ] **Step 3: Write the route**

`lib/ui/model/message_route.dart`:

```dart
/// Where a notification leads: one message in one room. Not called
/// `Route`, which Flutter's widgets library already exports.
library;

import 'package:flutter/foundation.dart';

@immutable
class MessageRoute {
  const MessageRoute(this.roomId, this.eventId);

  final String roomId;
  final String eventId;

  @override
  bool operator ==(Object other) =>
      other is MessageRoute &&
      other.roomId == roomId &&
      other.eventId == eventId;

  @override
  int get hashCode => Object.hash(roomId, eventId);

  @override
  String toString() => 'MessageRoute($roomId, $eventId)';
}
```

- [ ] **Step 4: Grow the interface**

In `lib/ui/channel/timeline.dart`, above `abstract interface class Timeline`:

```dart
/// What a jump to a message says when the message can't be had: deleted,
/// never visible to you, in a room you are not in, or out of reach.
const messageUnavailable = "that message isn't available";
```

Inside `Timeline`, after `void loadOlder();`:

```dart
  /// Whether there are messages newer than those loaded: the conversation
  /// was opened at an older message and has not caught up with the live
  /// end yet.
  bool get canLoadNewer;

  /// True while newer messages are being fetched.
  bool get loadingNewer;

  /// The last fetch of newer messages failed; [loadNewer] tries again.
  bool get loadNewerFailed;

  /// Fetches the next stretch towards the live end. Does nothing while a
  /// fetch is already running or once [canLoadNewer] is false.
  void loadNewer();

  /// Counts one up each time the conversation reopens on another stretch
  /// of history. The view starts its list over then, rather than keep a
  /// scroll position that belonged to other messages.
  int get stretch;

  /// The message to bring into view and light up, until the view has done
  /// so and called [jumpShown]. Set by [jumpTo] once the message is loaded.
  String? get jumpTarget;

  /// The view has shown [jumpTarget].
  void jumpShown();

  /// Brings [messageId] into view: at once when it is loaded, otherwise
  /// once the conversation has reopened around it. One that can't be had
  /// leaves the newest messages showing, and [failures] says so.
  void jumpTo(String messageId);

  /// Back to the newest messages, for a conversation opened further back.
  /// Does nothing at the live end.
  void showNewest();
```

- [ ] **Step 5: Implement it in the mock**

In `lib/ui/channel/timeline_controller.dart`, add `import 'dart:async';` and export `messageUnavailable`:

```dart
export 'timeline.dart'
    show Attachment, ComposerMode, ComposerTarget, Timeline, messageUnavailable;
```

Replace `Stream<String> get failures => const Stream.empty();` and add the rest beside `loadOlder`:

```dart
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
  void showNewest() {}

  final _failures = StreamController<String>.broadcast();
  @override
  Stream<String> get failures => _failures.stream;

  String? _jumpTarget;
  @override
  String? get jumpTarget => _jumpTarget;
  @override
  void jumpShown() => _jumpTarget = null;

  /// Everything the mock has is loaded, so a message it lacks never was.
  @override
  void jumpTo(String messageId) {
    if (!_messages.any((m) => m.id == messageId)) {
      _failures.add(messageUnavailable);
      return;
    }
    _jumpTarget = messageId;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_failures.close());
    super.dispose();
  }
```

- [ ] **Step 6: Keep the test fakes compiling**

Each of `test/channel_view_states_test.dart`, `test/channel_view_encryption_test.dart` and `test/channel_view_media_test.dart` has a `_FakeTimeline`/`_Timeline` that `implements Timeline`. Add to each:

```dart
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
  void jumpTo(String messageId) {}
  @override
  void showNewest() {}
```

`MatrixTimeline` won't compile yet either. Give it stubs so the suite builds; Task 2 replaces them:

```dart
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
  void jumpTo(String messageId) {}
  @override
  void showNewest() {}
```

- [ ] **Step 7: Run the tests, then the suite**

Run: `mise exec -- flutter test test/message_route_test.dart test/timeline_controller_test.dart`
Expected: PASS.
Run: `mise exec -- flutter test`
Expected: all pass (1445 + the new ones).

- [ ] **Step 8: Commit**

```bash
git add lib/ui/model/message_route.dart lib/ui/channel/timeline.dart lib/ui/channel/timeline_controller.dart lib/matrix/matrix_timeline.dart test/message_route_test.dart test/timeline_controller_test.dart test/channel_view_states_test.dart test/channel_view_encryption_test.dart test/channel_view_media_test.dart
git commit -m "feat(jump): a route to a message, and a timeline that can be asked to jump"
```

---

### Task 2: The SDK timeline jumps, pages forward, and catches up

**Files:**
- Modify: `lib/matrix/matrix_timeline.dart`
- Test: `test/matrix/matrix_timeline_jump_test.dart` (new; its own small harness, since `matrix_timeline_test.dart`'s is private and already 1344 lines)

**Interfaces:**
- Consumes: Task 1's `Timeline` members and `messageUnavailable`.
- Produces: `MatrixTimeline` implementing them for real:
  - `jumpTo(id)`: if loaded, it sets `jumpTarget` and notifies. Otherwise it reopens with `room.getTimeline(eventContextId: id)`, swaps the new SDK timeline in, `stretch++`, and sets `jumpTarget = id`. If that fails, it says `messageUnavailable` and reopens at the live end (only if not already live).
  - `loadNewer()` → `Timeline.requestFuture(historyCount: historyPage)`; clears the SDK's stuck `isRequestingFuture` on failure.
  - `showNewest()` → reopens live when `canLoadNewer`.
  - `send`/`sendFile` while `canLoadNewer` → reopen live first. `toggleReaction`/`saveEdit`/`delete` while `canLoadNewer` → page forward to live in the background.
  - `failures` buffers what is said while nobody listens and hands it to the first listener.

The SDK facts this leans on (`matrix` 13.0.0, `lib/src/room.dart` and `lib/src/timeline.dart`):

- `getTimeline(eventContextId:)` uses the database when the event is among the newest `limit` events there. Otherwise it calls `/context` and returns a fragmented timeline (`chunk.nextBatch != ''`), and throws if `/context` fails.
- A fragmented timeline has `allowNewEvent == false`: `_handleEventUpdate` drops every live event, your own echoes included. `canRequestFuture` is `!allowNewEvent`.
- `requestFuture` pages `/messages?dir=f`. A page without `end` sets `allowNewEvent = true`, and from then on the timeline is live.
- `requestFuture` sets `isRequestingFuture = false` only after a successful await. A throw leaves it true, and every later call returns at once.

- [ ] **Step 1: Write the harness and the failing tests**

`test/matrix/matrix_timeline_jump_test.dart`:

```dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_rooms.dart';
import 'package:loaf_native/matrix/matrix_timeline.dart';
import 'package:loaf_native/ui/channel/timeline.dart' show messageUnavailable;
import 'package:matrix/matrix.dart' hide Timeline;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';
const _ada = '@ada:example.com';
const _roomId = '!jump:example.com';

/// The fake server, plus what a jump needs of it for [_roomId]: the
/// context around an event, pages forward, and sends.
class _Api extends FakeMatrixApi {
  /// What `/context` answers for each event id. One not here is a 404.
  final contexts = <String, Map<String, Object?>>{};
  var refuseContext = false;

  /// Holds `/context` answers until completed, to race two jumps.
  Completer<void>? holdContext;

  /// What each forward page answers with, in turn.
  final forward = <Map<String, Object?>>[];
  var failForward = false;

  final contextAsked = <String>[];
  final sent = <String>[];
  var _ids = 0;

  static http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status);

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final path = Uri.decodeComponent(request.url.path);
    if (!path.contains('/rooms/$_roomId/')) return super.mockIntercept(request);
    if (request.method == 'GET' && path.contains('/context/')) {
      final id = path.split('/context/').last;
      contextAsked.add(id);
      await holdContext?.future;
      if (refuseContext) {
        return _json({'errcode': 'M_FORBIDDEN', 'error': 'no'}, 403);
      }
      final context = contexts[id];
      if (context == null) {
        return _json({'errcode': 'M_NOT_FOUND', 'error': 'gone'}, 404);
      }
      return _json(context);
    }
    if (request.method == 'GET' && path.endsWith('/messages')) {
      if (request.url.queryParameters['dir'] == 'f') {
        if (failForward) {
          return _json({'errcode': 'M_UNKNOWN', 'error': 'down'}, 500);
        }
        return _json(forward.removeAt(0));
      }
      // Nothing further back than what the test gives.
      return _json({'start': 'top', 'chunk': <Object>[]});
    }
    if (request.method == 'PUT' && path.contains('/send/')) {
      sent.add(path.split('/send/').last.split('/').first);
      return _json({'event_id': '\$sent${_ids++}'});
    }
    return super.mockIntercept(request);
  }
}

var _n = 0;
var _clock = 1700000000000;

Map<String, Object?> _event(
  String type,
  Map<String, Object?> content, {
  String sender = _ada,
  String? id,
  String? stateKey,
}) => {
  'type': type,
  'sender': sender,
  'content': content,
  'event_id': id ?? '\$e${_n++}',
  'origin_server_ts': _clock += 1000,
  'state_key': ?stateKey,
};

Map<String, Object?> _text(String body, {String? id, String sender = _ada}) =>
    _event('m.room.message', {
      'msgtype': 'm.text',
      'body': body,
    }, sender: sender, id: id);

Map<String, Object?> _member(String user, String name) => _event(
  'm.room.member',
  {'membership': 'join', 'displayname': name},
  sender: user,
  stateKey: user,
);

Future<void> _sync(Client client, List<Map<String, Object?>> events) =>
    client.handleSync(
      SyncUpdate.fromJson({
        'next_batch': 'b${_n++}',
        'rooms': {
          'join': {
            _roomId: {
              'state': {
                'events': [
                  _event('m.room.create', {'creator': _me}, stateKey: ''),
                  _member(_me, 'Me'),
                  _member(_ada, 'Ada'),
                ],
              },
              'timeline': {'events': events, 'prev_batch': 'p0', 'limited': true},
            },
          },
        },
      }),
    );

/// The context `/context` gives for [id]: [before] newest first, [after]
/// oldest first, and a forward token unless [live].
Map<String, Object?> _context(
  String id,
  String body, {
  List<Map<String, Object?>> before = const [],
  List<Map<String, Object?>> after = const [],
}) => {
  'start': 'back1',
  'end': 'fwd1',
  'event': _text(body, id: id),
  'events_before': before,
  'events_after': after,
  'state': <Object>[],
};

/// A forward page, oldest first. The last one, at the live end, has no
/// `end`.
Map<String, Object?> _page(
  List<Map<String, Object?>> chunk, {
  bool last = false,
}) => {'start': 'fwd${_n++}', if (!last) 'end': 'fwd${_n++}', 'chunk': chunk};

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

Future<void> _until(bool Function() done) async {
  final give = DateTime.now().add(const Duration(seconds: 10));
  while (!done() && DateTime.now().isBefore(give)) {
    await _settle();
  }
}

class _Harness {
  _Harness(this.api, this.client, this.rooms);
  final _Api api;
  final Client client;
  final MatrixRooms rooms;

  MatrixTimeline get timeline => rooms.timeline(_roomId)! as MatrixTimeline;
  List<String> get bodies => [for (final m in timeline.messages) m.body];
}

/// A room whose newest messages are `now 1` and `now 2`, opened.
Future<_Harness> _open() async {
  final api = _Api();
  final client = await openClient(
    httpClient: api,
    databasePath: inMemoryDatabasePath,
  );
  FakeMatrixApi.client = client;
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse('https://fakeServer.notExisting'),
    newUserID: _me,
    newDeviceID: 'GHTYAJCE',
    newDeviceName: 'loaf on test',
    waitForFirstSync: false,
  );
  addTearDown(client.dispose);
  await _sync(client, [_text('now 1', id: r'$now1'), _text('now 2')]);
  final rooms = MatrixRooms(client);
  addTearDown(rooms.dispose);
  final h = _Harness(api, client, rooms);
  await _until(() => !h.timeline.loadingOlder);
  await _settle();
  return h;
}

void main() {
  test('a loaded message is jumped to in place', () async {
    final h = await _open();
    h.timeline.jumpTo(r'$now1');
    expect(h.timeline.jumpTarget, r'$now1');
    expect(h.timeline.stretch, 0);
    expect(h.api.contextAsked, isEmpty);
  });

  test('an older message reopens the conversation around it', () async {
    final h = await _open();
    h.api.contexts[r'$old'] = _context(
      r'$old',
      'the old one',
      before: [_text('just before')],
      after: [_text('just after')],
    );
    h.timeline.jumpTo(r'$old');
    await _until(() => h.timeline.jumpTarget != null);
    expect(h.timeline.jumpTarget, r'$old');
    expect(h.bodies, ['just before', 'the old one', 'just after']);
    expect(h.timeline.canLoadNewer, isTrue);
    expect(h.timeline.stretch, 1);
  });

  test('scrolling down pages forward until it is live', () async {
    final h = await _open();
    h.api.contexts[r'$old'] = _context(r'$old', 'the old one');
    h.api.forward
      ..add(_page([_text('later 1')]))
      ..add(_page([_text('later 2')], last: true));
    h.timeline.jumpTo(r'$old');
    await _until(() => h.timeline.jumpTarget != null);

    h.timeline.loadNewer();
    expect(h.timeline.loadingNewer, isTrue);
    await _until(() => !h.timeline.loadingNewer);
    expect(h.bodies, ['the old one', 'later 1']);
    expect(h.timeline.canLoadNewer, isTrue);

    h.timeline.loadNewer();
    await _until(() => !h.timeline.loadingNewer);
    expect(h.bodies, ['the old one', 'later 1', 'later 2']);
    expect(h.timeline.canLoadNewer, isFalse);

    // Live now: what sync brings lands.
    await _sync(h.client, [_text('brand new')]);
    await _settle();
    expect(h.bodies.last, 'brand new');
  });

  test('a failed newer page can be tried again', () async {
    final h = await _open();
    h.api.contexts[r'$old'] = _context(r'$old', 'the old one');
    h.timeline.jumpTo(r'$old');
    await _until(() => h.timeline.jumpTarget != null);

    h.api.failForward = true;
    h.timeline.loadNewer();
    await _until(() => !h.timeline.loadingNewer);
    expect(h.timeline.loadNewerFailed, isTrue);

    h.api
      ..failForward = false
      ..forward.add(_page([_text('later')], last: true));
    h.timeline.loadNewer();
    await _until(() => !h.timeline.loadingNewer);
    expect(h.timeline.loadNewerFailed, isFalse);
    expect(h.bodies, ['the old one', 'later']);
  });

  for (final refused in [false, true]) {
    test('a message the server '
        '${refused ? 'refuses' : 'no longer has'} keeps the newest, '
        'and says so', () async {
      final h = await _open();
      h.api.refuseContext = refused;
      h.timeline.jumpTo(r'$gone');
      await _until(() => h.api.contextAsked.isNotEmpty);
      await _settle();
      // Heard by a listener that came after: the view may not be up yet.
      final said = <String>[];
      h.timeline.failures.listen(said.add);
      await _settle();
      expect(said, [messageUnavailable]);
      expect(h.bodies, ['now 1', 'now 2']);
      expect(h.timeline.canLoadNewer, isFalse);
      expect(h.timeline.jumpTarget, isNull);
    });
  }

  test('a message that is gone, from back in history, opens the newest', () async {
    final h = await _open();
    h.api.contexts[r'$old'] = _context(r'$old', 'the old one');
    h.timeline.jumpTo(r'$old');
    await _until(() => h.timeline.jumpTarget != null);
    h.timeline.jumpShown();

    h.timeline.jumpTo(r'$gone');
    await _until(() => !h.timeline.canLoadNewer);
    expect(h.bodies, ['now 1', 'now 2']);
    expect(h.timeline.jumpTarget, isNull);
  });

  test('a later jump overtakes an earlier one', () async {
    final h = await _open();
    h.api
      ..contexts[r'$first'] = _context(r'$first', 'first')
      ..contexts[r'$second'] = _context(r'$second', 'second')
      ..holdContext = Completer<void>();
    h.timeline
      ..jumpTo(r'$first')
      ..jumpTo(r'$second');
    await _until(() => h.api.contextAsked.length == 2);
    h.api.holdContext!.complete();
    await _until(() => h.timeline.jumpTarget != null);
    await _settle();
    expect(h.timeline.jumpTarget, r'$second');
    expect(h.bodies, ['second']);
  });

  test('showNewest after a jump reopens at the live end', () async {
    final h = await _open();
    h.api.contexts[r'$old'] = _context(r'$old', 'the old one');
    h.timeline.jumpTo(r'$old');
    await _until(() => h.timeline.jumpTarget != null);
    h.timeline.jumpShown();

    h.timeline.showNewest();
    await _until(() => !h.timeline.canLoadNewer);
    expect(h.bodies, ['now 1', 'now 2']);
    expect(h.timeline.stretch, 2);
  });

  test('showNewest at the live end changes nothing', () async {
    final h = await _open();
    h.timeline.showNewest();
    await _settle();
    expect(h.timeline.stretch, 0);
  });

  test('sending while back in history returns to the newest first', () async {
    final h = await _open();
    h.api.contexts[r'$old'] = _context(r'$old', 'the old one');
    h.timeline.jumpTo(r'$old');
    await _until(() => h.timeline.jumpTarget != null);

    h.timeline.send('hello again');
    await _until(() => h.api.sent.isNotEmpty);
    await _settle();
    expect(h.timeline.canLoadNewer, isFalse);
    expect(h.bodies, ['now 1', 'now 2', 'hello again']);
  });

  test('reacting while back in history catches up, keeping the message', () async {
    final h = await _open();
    h.api.contexts[r'$old'] = _context(r'$old', 'the old one');
    h.api.forward.add(_page([_text('later')], last: true));
    h.timeline.jumpTo(r'$old');
    await _until(() => h.timeline.jumpTarget != null);

    h.timeline.toggleReaction(r'$old', '👍');
    await _until(() => !h.timeline.canLoadNewer && h.api.sent.isNotEmpty);
    expect(h.api.sent, ['m.reaction']);
    expect(h.bodies, ['the old one', 'later']);

    // Live: the reaction's own copy, when sync brings it, shows on it.
    await _sync(h.client, [
      _event('m.reaction', {
        'm.relates_to': {
          'rel_type': 'm.annotation',
          'event_id': r'$old',
          'key': '👍',
        },
      }, sender: _me, id: r'$sent0'),
    ]);
    await _settle();
    final old = h.timeline.messages.firstWhere((m) => m.id == r'$old');
    expect(old.reactions.single.emoji, '👍');
  });
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `mise exec -- flutter test test/matrix/matrix_timeline_jump_test.dart`
Expected: FAIL. The Task 1 stubs never set a target, never page, and never say anything.

- [ ] **Step 3: Buffer failures until someone listens**

In `lib/matrix/matrix_timeline.dart`, import `messageUnavailable` (`import '../ui/channel/timeline.dart' as ui;` is already there, so use `ui.messageUnavailable`). Replace the `_failures` field with:

```dart
  /// What went wrong, as toasts. A jump can fail before the view that
  /// would show it is up (a notification opening the app), so anything
  /// said while nobody listens waits for the first listener.
  late final _failures = StreamController<String>.broadcast(
    onListen: _flushUnheard,
  );
  final _unheard = <String>[];

  void _fail(String text) {
    if (_disposed) return;
    if (_failures.hasListener) {
      _failures.add(text);
    } else {
      _unheard.add(text);
    }
  }

  void _flushUnheard() {
    final waiting = [..._unheard];
    _unheard.clear();
    waiting.forEach(_failures.add);
  }
```

Then change the two existing `_failures.add(...)` calls (in `_attempt` and in `sendFile`'s too-big branch) to `_fail(...)`. `_attempt` already checks `_disposed`, and `_fail` checks again; that's fine.

- [ ] **Step 4: Open at a message, and reopen**

Add fields beside `_opening`:

```dart
  var _newerFailed = false;
  Future<void>? _newer;
  String? _jumpTarget;
  var _stretch = 0;

  /// Counts openings, so a slow one overtaken by a later jump is dropped.
  var _openings = 0;
```

Replace `_open` with:

```dart
  /// Opens the conversation at the live end, or around [at]. Reopening
  /// keeps the messages on screen until the new ones are in.
  Future<void> _open({String? at}) async {
    final opening = ++_openings;
    if (_timeline == null) _opening = true;
    _pageFailed = false;
    _newerFailed = false;
    _changed();
    Timeline? timeline;
    try {
      timeline = await room.getTimeline(
        limit: historyPage,
        onUpdate: _changed,
        eventContextId: at,
      );
    } on Object {
      timeline = null;
    }
    if (_disposed || opening != _openings) {
      timeline?.cancelSubscriptions();
      return;
    }
    if (timeline == null && at != null) {
      // Deleted, never yours to see, or out of reach: the newest messages
      // are the nearest there is. Already there, you stay where you were.
      _fail(ui.messageUnavailable);
      if (canLoadNewer) return _open();
      _opening = false;
      _changed();
      return;
    }
    if (timeline == null) {
      // Offline, or the database had nothing to give: loading older
      // messages is how to try again.
      _pageFailed = true;
    } else {
      final previous = _timeline;
      _timeline = timeline;
      if (previous != null) {
        previous.cancelSubscriptions();
        _stretch++;
      }
      _jumpTarget = at;
    }
    _opening = false;
    _changed();
  }
```

Remove the Task 1 stubs and add:

```dart
  // ── Jumping ────────────────────────────────────────────────────────────

  @override
  int get stretch => _stretch;

  @override
  String? get jumpTarget => _jumpTarget;

  // Nothing to redraw: the view has already drawn it.
  @override
  void jumpShown() => _jumpTarget = null;

  @override
  void jumpTo(String messageId) {
    if (_event(messageId) != null) {
      _jumpTarget = messageId;
      _changed();
      return;
    }
    unawaited(_open(at: messageId));
  }

  @override
  void showNewest() {
    if (!canLoadNewer) return;
    _jumpTarget = null;
    unawaited(_open());
  }
```

- [ ] **Step 5: Page forward**

Add beside `loadOlder`:

```dart
  /// Short of the live end: the SDK's timeline was opened around an older
  /// message, and hears nothing live until it has paged forward to now.
  @override
  bool get canLoadNewer => _timeline?.canRequestFuture ?? false;

  @override
  bool get loadingNewer => _newer != null;

  @override
  bool get loadNewerFailed => _newerFailed;

  @override
  void loadNewer() {
    if (_opening || _newer != null || !canLoadNewer) return;
    unawaited(_pageNewer());
  }

  /// One page towards the live end, shared by whoever asks while it runs.
  /// The SDK clears its own "requesting" flag only on success, so after a
  /// failure it is cleared here, or no page would ever be asked for again.
  Future<void> _pageNewer() => _newer ??= () async {
    final timeline = _timeline!;
    _newerFailed = false;
    _changed();
    try {
      await timeline.requestFuture(historyCount: historyPage);
    } on Object {
      timeline.isRequestingFuture = false;
      _newerFailed = true;
    } finally {
      _newer = null;
      _changed();
    }
  }();

  /// Pages forward to the live end, so a reaction, edit or deletion lands
  /// in a timeline that hears it, without losing your place. Stops at a
  /// failed page, or one that brought nothing: the write has gone either
  /// way, and scrolling down tries again.
  Future<void> _catchUp() async {
    while (!_disposed && canLoadNewer) {
      final before = _timeline?.events.length;
      await _pageNewer();
      if (_newerFailed || _timeline?.events.length == before) return;
    }
  }

  void _catchUpForWrite() {
    if (canLoadNewer) unawaited(_catchUp());
  }

  /// Back to the live end before sending. A timeline opened further back
  /// hears nothing new, so the message would never show, and sending is
  /// talking now: the newest messages are where to be.
  Future<void> _toLive() => canLoadNewer ? _open() : Future<void>.value();
```

- [ ] **Step 6: Route writes through them**

In `send`, wrap the existing `_send(...)` call so it waits for `_toLive()` (the `replyTo` event is looked up before, and stays valid):

```dart
    unawaited(
      _toLive()
          .then(
            (_) => _send(
              (txid) => mentions.isEmpty
                  ? room.sendTextEvent(/* unchanged arguments */)
                  : room.sendEvent(/* unchanged arguments */),
            ),
          )
          .then<void>((_) {}, onError: (Object _) {}),
    );
```

In `sendFile`, wrap the same way: `_toLive().then((_) => _send((txid) { ... }))`, keeping the existing `.then<void>(..., onError: ...)` that handles too-big files.

At the top of `toggleReaction`, `saveEdit` and `delete`, add `_catchUpForWrite();`. Leave `retry` and `discard` alone: an unsent message only exists in a live timeline.

- [ ] **Step 7: Run the jump tests, then both timeline suites**

Run: `mise exec -- flutter test test/matrix/matrix_timeline_jump_test.dart`
Expected: PASS.
Run: `mise exec -- flutter test test/matrix/matrix_timeline_test.dart test/matrix/matrix_timeline_encrypted_test.dart test/matrix/matrix_rooms_test.dart`
Expected: PASS. This proves the `_open` and `send` rewiring didn't break the live path.

- [ ] **Step 8: Commit**

```bash
git add lib/matrix/matrix_timeline.dart test/matrix/matrix_timeline_jump_test.dart
git commit -m "feat(jump): open a room's timeline around a message, and page forward to live"
```

---

### Task 3: The channel view scrolls to the message, lights it, and loads forward

**Files:**
- Modify: `lib/ui/channel/channel_view.dart` (`ChannelView.build`'s timeline child, `_TimelineState`, `_OlderLine` → `_PageLine`)
- Modify: `lib/ui/channel/message_group_tile.dart` (`MessageGroupTile.focus`, `_JumpGlow`)
- Test: `test/channel_jump_test.dart` (new)

**Interfaces:**
- Consumes: Task 1's `Timeline` members.
- Produces:
  - `typedef JumpFocus = ({String id, GlobalKey key, bool lit});` and `MessageGroupTile({..., JumpFocus? focus})`. The focused message's row is wrapped in a glow carrying `focus.key`. The glow's `AnimatedContainer` has `key: ValueKey('jump-glow')`, and its colour is `tokens.accent` at alpha 0.18 while `lit`, else 0.
  - The view calls `jumpShown()` once it has shown a target, and `loadNewer()` within a screen of the bottom.

Why a `CustomScrollView` with `center`: in a reversed `ListView`, messages added at the newest end push everything on screen up by their height. With the list split at the jumped-to message into two slivers, and the older one as `center`, newer pages grow into negative scroll offsets below it, and what you are reading stays put. Without a jump the newer sliver is empty, and the list behaves as it does today.

- [ ] **Step 1: Write the failing widget tests**

`test/channel_jump_test.dart`:

```dart
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
List<Message> _messages(int from, int to, {Map<int, int> replies = const {}}) => [
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

Future<void> _pump(WidgetTester tester, TimelineController timeline) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(timeline.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(
        body: ChannelView(channel: _channel, timeline: timeline),
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
  setUp(() {});

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

  testWidgets('a target that draws no row is let go quietly', (tester) async {
    _tester = tester;
    final timeline = _Paged(_messages(0, 30), const []);
    await _pump(tester, timeline);
    timeline.forceTarget('deleted');
    await tester.pumpAndSettle();
    expect(timeline.jumpTarget, isNull);
    expect(find.byKey(const ValueKey('jump-glow')), findsNothing);
    expect(_onScreen('message 30'), isTrue);
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
    await tester.tap(find.text('try again'));
    await tester.pumpAndSettle();
    expect(timeline.retried, 1);
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
}

/// Short of live, and its last newer page failed.
class _FailingNewer extends TimelineController {
  _FailingNewer(super.messages) : super(you: _you);
  var retried = 0;
  @override
  bool get canLoadNewer => true;
  @override
  bool get loadNewerFailed => retried == 0;
  @override
  void loadNewer() {
    retried++;
    notifyListeners();
  }
}
```

(Remove the empty `setUp` if the analyzer complains. `messageUnavailable` comes from `timeline_controller.dart`'s export.)

- [ ] **Step 2: Run them to see them fail**

Run: `mise exec -- flutter test test/channel_jump_test.dart`
Expected: FAIL. There is no `CustomScrollView`, no glow and no newer line.

- [ ] **Step 3: The glow in the group tile**

In `lib/ui/channel/message_group_tile.dart`:

```dart
/// A message jumped to: [key] goes on its row so the timeline can bring
/// it into view, and while [lit] it glows.
typedef JumpFocus = ({String id, GlobalKey key, bool lit});
```

Add `this.focus` to `MessageGroupTile`'s constructor with the field:

```dart
  /// The message in this group that was jumped to, if any.
  final JumpFocus? focus;
```

Restructure `_interactive` so both branches assign to `final Widget row = ...;` instead of returning, then end with:

```dart
    final focus = this.focus;
    if (focus == null || focus.id != message.id) return row;
    return _JumpGlow(key: focus.key, lit: focus.lit, child: row);
```

Add below `_Highlight`:

```dart
/// How long the glow takes to fade once the message has been seen.
const _glowFade = Duration(milliseconds: 600);

/// The accent wash behind a message jumped to, so the eye finds where it
/// landed. Unlike [_Highlight] it is the accent, not the card: it marks a
/// place rather than a pointer.
class _JumpGlow extends StatelessWidget {
  const _JumpGlow({super.key, required this.lit, required this.child});

  final bool lit;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: -LoafSpace.x2,
          right: -LoafSpace.x2,
          top: -2,
          bottom: -2,
          child: AnimatedContainer(
            key: const ValueKey('jump-glow'),
            duration: _glowFade,
            curve: LoafMotion.ease,
            decoration: BoxDecoration(
              color: tokens.accent.withValues(alpha: lit ? 0.18 : 0),
              borderRadius: BorderRadius.circular(LoafRadius.md),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
```

- [ ] **Step 4: Key the list by stretch**

In `ChannelView.build`, replace the `_Timeline(key: ObjectKey(timeline), ...)` child with:

```dart
                    // Keyed by the conversation and the stretch of it
                    // loaded: switching rooms, or reopening on other
                    // messages, starts a fresh list.
                    ListenableBuilder(
                      listenable: timeline!,
                      builder: (context, _) => _Timeline(
                        key: ValueKey((timeline, timeline!.stretch)),
                        controller: timeline!,
                        onRead: onRead,
                      ),
                    ),
```

- [ ] **Step 5: Rewrite `_TimelineState`**

Add the constants beside `_olderKey`:

```dart
/// The bottom "newer messages" line.
const _newerKey = ValueKey('newer');

/// The sliver the list grows from. After a jump, the jumped-to message's
/// group starts it, and newer messages fill in below without moving what
/// is on screen. Otherwise it holds the whole conversation.
const _centerKey = ValueKey('center');

/// How long a message jumped to stays lit before it fades.
const _litFor = Duration(milliseconds: 1600);
```

New fields in `_TimelineState`:

```dart
  final _focusKey = GlobalKey();

  /// Short of the live end when last heard from. What lands at the bottom
  /// then is a page coming in, not a message arriving.
  late bool _short;

  /// The message the list grows from, once one has been jumped to.
  String? _split;

  /// Whether the message jumped to is still lit.
  bool _lit = false;
  Timer? _unlight;
```

`initState`: set `_short = widget.controller.canLoadNewer;`, change `_scroll.addListener(_maybeLoadOlder)` to `_scroll.addListener(_maybeLoadMore)`, and after `_checkFilled();` add `WidgetsBinding.instance.addPostFrameCallback((_) => _maybeReveal());`. `dispose`: add `_unlight?.cancel();`.

`_onMessages` becomes:

```dart
  void _onMessages() {
    final controller = widget.controller;
    final last = controller.messages.lastOrNull;
    final paged = _short;
    _short = controller.canLoadNewer;
    final arrived = last != null && last.id != _lastId && !paged;
    _lastId = last?.id;
    setState(() {});
    _checkFilled();
    _maybeReveal();
    if (!arrived) return;
    if (last.author.id == controller.you.id) {
      if (_scroll.hasClients) {
        // The newest end: below any jump's split, so not always offset 0.
        _scroll.animateTo(
          _scroll.position.minScrollExtent,
          duration: LoafMotion.normal,
          curve: LoafMotion.ease,
        );
      }
    } else if (_looking) {
      widget.onRead?.call();
    } else {
      _unreadWhileAway = true;
    }
  }
```

Add:

```dart
  /// Brings the message jumped to into view and lights it. One that draws
  /// no row (deleted, or not a message) is let go: the conversation is
  /// already open around where it was.
  void _maybeReveal() {
    final controller = widget.controller;
    final target = controller.jumpTarget;
    if (!mounted || target == null) return;
    controller.jumpShown();
    if (!controller.messages.any((m) => m.id == target)) return;
    _unlight?.cancel();
    setState(() {
      _split = target;
      _lit = true;
    });
    // Split there, the target sits at offset 0, so it is built: go there,
    // then centre it once it is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final context = _focusKey.currentContext;
        if (mounted && context != null) {
          unawaited(Scrollable.ensureVisible(context, alignment: 0.5));
        }
      });
    });
    _unlight = Timer(_litFor, () {
      if (mounted) setState(() => _lit = false);
    });
  }

  void _maybeLoadMore() {
    _maybeLoadOlder();
    _maybeLoadNewer();
  }

  /// Within a screen of the newest message loaded, short of the live end:
  /// fetch more. The list is reversed, so the newest end is the near end.
  void _maybeLoadNewer() {
    final timeline = widget.controller;
    if (!timeline.canLoadNewer ||
        timeline.loadingNewer ||
        timeline.loadNewerFailed ||
        !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    if (position.extentBefore < position.viewportDimension) {
      timeline.loadNewer();
    }
  }
```

`_checkFilled` calls `_maybeLoadMore()` instead of `_maybeLoadOlder()`.

Replace `build`:

```dart
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final entries = groupTimeline(controller.messages).reversed.toList();
    final split = _split;
    final at = split == null
        ? -1
        : entries.indexWhere(
            (e) => e is MessageGroup && e.messages.any((m) => m.id == split),
          );
    // Newest first in both: [newer] runs down from the split, [older] up.
    final newer = entries.sublist(0, at < 0 ? 0 : at).reversed.toList();
    final older = entries.sublist(at < 0 ? 0 : at);
    final top = controller.loadingOlder
        ? const _PageLine(newer: false, failed: false)
        : controller.loadOlderFailed
        ? _PageLine(newer: false, failed: true, onRetry: controller.loadOlder)
        : null;
    final bottom = controller.loadingNewer
        ? const _PageLine(newer: true, failed: false)
        : controller.loadNewerFailed
        ? _PageLine(newer: true, failed: true, onRetry: controller.loadNewer)
        : null;
    final belowSplit = newer.isNotEmpty || bottom != null;
    // Each list matches its children by key, not by place: a new message
    // shifts every entry along one, and each must keep its own State (a
    // video playing in it) rather than take its neighbour's.
    final newerIndex = <Key, int>{
      for (var i = 0; i < newer.length; i++) _keyOf(newer[i]): i,
      if (bottom != null) _newerKey: newer.length,
    };
    final olderIndex = <Key, int>{
      for (var i = 0; i < older.length; i++) _keyOf(older[i]): i,
      if (top != null) _olderKey: older.length,
    };
    return CustomScrollView(
      controller: _scroll,
      reverse: true,
      center: _centerKey,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            LoafSpace.x4,
            0,
            LoafSpace.x4,
            belowSplit ? LoafSpace.x2 : 0,
          ),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => index == newer.length
                  ? KeyedSubtree(key: _newerKey, child: bottom!)
                  : _entry(newer[index]),
              childCount: newer.length + (bottom == null ? 0 : 1),
              findChildIndexCallback: (key) => newerIndex[key],
            ),
          ),
        ),
        SliverPadding(
          key: _centerKey,
          padding: EdgeInsets.fromLTRB(
            LoafSpace.x4,
            LoafSpace.x2,
            LoafSpace.x4,
            belowSplit ? 0 : LoafSpace.x2,
          ),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => index == older.length
                  ? KeyedSubtree(key: _olderKey, child: top!)
                  : _entry(older[index]),
              childCount: older.length + (top == null ? 0 : 1),
              findChildIndexCallback: (key) => olderIndex[key],
            ),
          ),
        ),
      ],
    );
  }

  Widget _entry(TimelineEntry entry) {
    final split = _split;
    return KeyedSubtree(
      key: _keyOf(entry),
      child: switch (entry) {
        DaySeparator() => _DaySeparatorTile(entry: entry),
        CallEntry() => _CallLineTile(message: entry.message),
        MessageGroup() => Padding(
          padding: const EdgeInsets.only(bottom: LoafSpace.x4),
          child: MessageGroupTile(
            group: entry,
            controller: widget.controller,
            focus: split != null && entry.messages.any((m) => m.id == split)
                ? (id: split, key: _focusKey, lit: _lit)
                : null,
          ),
        ),
      },
    );
  }
```

- [ ] **Step 6: One page line for both ends**

Rename `_OlderLine` to `_PageLine`, add `required this.newer`, and pick the copy by it:

```dart
/// The top of a conversation while older messages are on their way, or
/// the bottom while newer ones are; or, at either end, that fetching them
/// failed.
class _PageLine extends StatelessWidget {
  const _PageLine({required this.newer, required this.failed, this.onRetry});

  final bool newer;
  final bool failed;
  final VoidCallback? onRetry;
```

In its `build`, `"couldn't load older messages · "` becomes `"couldn't load ${newer ? 'newer' : 'older'} messages · "` and `'loading older messages'` becomes `'loading ${newer ? 'newer' : 'older'} messages'`.

- [ ] **Step 7: Run the jump tests, then every channel view test**

Run: `mise exec -- flutter test test/channel_jump_test.dart`
Expected: PASS.
Run: `mise exec -- flutter test test/channel_view_states_test.dart test/channel_view_encryption_test.dart test/channel_view_media_test.dart test/message_group_tile_test.dart test/group_timeline_test.dart test/app_shell_test.dart test/app_shell_rooms_test.dart`
Expected: PASS. The list behaves as before when there's no jump: older loading, your own message scrolling down, read on arrival.

- [ ] **Step 8: Commit**

```bash
git add lib/ui/channel/channel_view.dart lib/ui/channel/message_group_tile.dart test/channel_jump_test.dart
git commit -m "feat(jump): the conversation scrolls to a message, lights it, and loads forward"
```

---

### Task 4: Tapping a reply's quote jumps to what it answers

**Files:**
- Modify: `lib/ui/channel/message_group_tile.dart` (`_MessageBody.onOpenReply`, `_ReplyContext.onTap`, both callers of `_MessageBody` in `_TouchMessage` and `_PointerMessage`)
- Test: `test/channel_jump_test.dart`

**Interfaces:**
- Consumes: `Timeline.jumpTo` (Task 1). In the view, Task 3's reveal.
- Produces: no new public names.

- [ ] **Step 1: Write the failing tests**

Append to `main()` in `test/channel_jump_test.dart`:

```dart
  for (final platform in [TargetPlatform.macOS, TargetPlatform.iOS]) {
    testWidgets("tapping a reply's quote jumps to what it answers", variant:
        TargetPlatformVariant.only(platform), (tester) async {
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
    });
  }
```

- [ ] **Step 2: Run it to see it fail**

Run: `mise exec -- flutter test test/channel_jump_test.dart`
Expected: the two new tests FAIL (the quote isn't tappable).

- [ ] **Step 3: Make the quote a way there**

`_ReplyContext` gets `this.onTap` (`final VoidCallback? onTap;`). Wrap its returned `Padding` so that:

```dart
    final quote = Padding(/* unchanged */);
    final onTap = this.onTap;
    if (onTap == null) return quote;
    // The quote is a way to what it answers: a pointer says so.
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: quote,
      ),
    );
```

`_MessageBody` gets `this.onOpenReply` with:

```dart
  /// Tapping the quote of what this replies to goes there. Null leaves the
  /// quote display-only.
  final VoidCallback? onOpenReply;
```

It passes it on: `_ReplyContext(replyTo: replyTo, onTap: onOpenReply)`.

In both `_TouchMessage` and `_PointerMessage`, where they build `_MessageBody`, add:

```dart
        onOpenReply: widget.message.replyTo == null
            ? null
            : () => widget.controller.jumpTo(widget.message.replyTo!.id),
```

(The display-only and locked branch in `MessageGroupTile._interactive` passes nothing: there is no controller there, or nothing to read.)

- [ ] **Step 4: Run the tests**

Run: `mise exec -- flutter test test/channel_jump_test.dart test/message_group_tile_test.dart test/message_actions_test.dart`
Expected: PASS. The long press on a phone and the hover toolbar on desktop still behave.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/channel/message_group_tile.dart test/channel_jump_test.dart
git commit -m "feat(jump): tapping a reply's quote goes to the message it answers"
```

---

### Task 5: The shell follows routes

**Files:**
- Modify: `lib/ui/shell/app_shell.dart` (`AppShell.routes`, `_follow`, `_onChange`, `_goTo`, `_selectChannel`, `dispose`)
- Modify: `docs/superpowers/specs/2026-10-06-notifications-design.md` (section B, and D's `clicks` type)
- Test: `test/app_shell_rooms_test.dart` (its `_FakeRooms` gains timelines; a new group)

**Interfaces:**
- Consumes: `MessageRoute` and `messageUnavailable` (Task 1), `Timeline.jumpTo`/`showNewest`.
- Produces: `AppShell({..., Stream<MessageRoute>? routes})`. Steps D and E pass their click and tap streams here.

- [ ] **Step 1: Write the failing tests**

In `test/app_shell_rooms_test.dart`:

1. Import `package:loaf_native/ui/channel/timeline_controller.dart` and `package:loaf_native/ui/model/message_route.dart`.
2. In `_FakeRooms`, replace `Timeline? timeline(String roomId) => null;` with:

```dart
  /// The conversations it can open, by room.
  final timelines = <String, Timeline>{};

  @override
  Timeline? timeline(String roomId) => timelines[roomId];
```

3. Give `_pump` a `Stream<MessageRoute>? routes` parameter and pass `routes: routes` to `AppShell`.
4. Add the group:

```dart
  group('following a route to a message', () {
    /// Twenty messages in [roomId], ids `<roomId>-0` to `-19`.
    TimelineController conversation(String roomId) => TimelineController([
      for (var i = 0; i < 20; i++)
        Message(
          id: '$roomId-$i',
          author: i.isEven ? _me : _mod,
          sentAt: DateTime(2026, 10, 6, 9, i),
          body: '$roomId says $i',
        ),
    ], you: _me);

    _FakeRooms withConversations({List<Space>? spaces}) {
      final rooms = _FakeRooms(
        spaces: spaces ?? [_bakery()],
        homeRooms: const [_dm],
      )..abilities = {RoomAbility.answerInvites, RoomAbility.messages};
      for (final id in ['!general', '!dm']) {
        rooms.timelines[id] = conversation(id);
      }
      addTearDown(() {
        for (final t in rooms.timelines.values) {
          (t as TimelineController).dispose();
        }
      });
      return rooms;
    }

    Finder header(String name) => find.descendant(
      of: find.byType(ChannelView),
      matching: find.text(name),
    );

    testWidgets('opens the channel in its space, at the message', (
      tester,
    ) async {
      final routes = StreamController<MessageRoute>();
      addTearDown(routes.close);
      final rooms = withConversations();
      await _pump(tester, rooms, routes: routes.stream);

      routes.add(const MessageRoute('!general', '!general-3'));
      await tester.pumpAndSettle();
      expect(header('general'), findsOneWidget);
      expect(rooms.timelines['!general']!.jumpTarget, isNull); // Shown.
      expect(find.byKey(const ValueKey('jump-glow')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a DM opens in Home', (tester) async {
      final routes = StreamController<MessageRoute>();
      addTearDown(routes.close);
      final rooms = withConversations();
      await _pump(tester, rooms, routes: routes.stream);
      await tester.tap(find.byTooltip('Bakery'));
      await tester.pumpAndSettle();

      routes.add(const MessageRoute('!dm', '!dm-2'));
      await tester.pumpAndSettle();
      expect(header('Moddy'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a room you are not in says so, and stays put', (
      tester,
    ) async {
      final routes = StreamController<MessageRoute>();
      addTearDown(routes.close);
      final rooms = withConversations();
      await _pump(tester, rooms, routes: routes.stream);
      routes.add(const MessageRoute('!dm', '!dm-2'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));

      routes.add(const MessageRoute('!left', r'$any'));
      await tester.pumpAndSettle();
      expect(find.text(messageUnavailable), findsOneWidget);
      expect(header('Moddy'), findsOneWidget);
    });

    testWidgets('a route before the first sync waits for it', (tester) async {
      final routes = StreamController<MessageRoute>();
      addTearDown(routes.close);
      final rooms = withConversations()..synced = false;
      await _pump(tester, rooms, routes: routes.stream, settle: false);

      routes.add(const MessageRoute('!general', '!general-3'));
      await tester.pump();
      expect(find.text(messageUnavailable), findsNothing);

      rooms
        ..synced = true
        ..update();
      await tester.pumpAndSettle();
      expect(header('general'), findsOneWidget);
      expect(find.byKey(const ValueKey('jump-glow')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a room in the space you are in stays there', (tester) async {
      final routes = StreamController<MessageRoute>();
      addTearDown(routes.close);
      final second = Space(
        id: '!second',
        name: 'Second',
        color: const Color(0xFF4E9E76),
        members: const [_me],
        categories: [
          ChannelCategory('', const [Channel(id: '!general', name: 'general')]),
        ],
      );
      final rooms = withConversations(spaces: [_bakery(), second]);
      await _pump(tester, rooms, routes: routes.stream);
      await tester.tap(find.byTooltip('Second'));
      await tester.pumpAndSettle();

      routes.add(const MessageRoute('!general', '!general-3'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ChannelList),
          matching: find.text('Second'),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 2));
    });
  });
```

Before relying on `find.byTooltip('Bakery')`, check how the existing tests in this file select a space on the rail (`grep -n "SpacesRail\|byTooltip" test/app_shell_rooms_test.dart`) and use the same finder. Import `ChannelView` (`package:loaf_native/ui/channel/channel_view.dart`) if it isn't imported already.

- [ ] **Step 2: Run them to see them fail**

Run: `mise exec -- flutter test test/app_shell_rooms_test.dart`
Expected: compile error (`routes` is not a parameter).

- [ ] **Step 3: Follow routes in the shell**

In `lib/ui/shell/app_shell.dart`, import `../model/message_route.dart` and `../channel/timeline.dart` (for `messageUnavailable`, if `channel_view.dart` doesn't already export it).

On `AppShell`:

```dart
  const AppShell({super.key, this.session, this.rooms, this.updater, this.routes});

  /// Messages to open, as notifications are clicked or tapped. One that
  /// comes before the first sync waits for it.
  final Stream<MessageRoute>? routes;
```

In `_AppShellState`:

```dart
  StreamSubscription<MessageRoute>? _routes;

  /// A route that came before the rooms were synced: its room may not be
  /// known yet, so it waits rather than say the message isn't there.
  MessageRoute? _heldRoute;
```

At the end of `initState`: `_routes = widget.routes?.listen(_follow);`. In `dispose`: `unawaited(_routes?.cancel());`.

Replace `_onChange`:

```dart
  void _onChange() {
    final held = _heldRoute;
    if (held != null && _rooms.synced) {
      _heldRoute = null;
      _follow(held);
    }
    setState(() {});
  }
```

Add, beside `_goTo`:

```dart
  /// Opens the message [route] names. Its room opens where [_goTo] puts
  /// it, then the conversation brings the message into view. A room you
  /// are not in has nothing to open, so you stay where you are.
  void _follow(MessageRoute route) {
    if (!mounted) return;
    if (!_rooms.synced) {
      _heldRoute = route;
      return;
    }
    final id = route.roomId;
    final joined =
        !_spaces.any((s) => s.id == id) && _joinedIds.contains(id);
    final timeline = joined ? _rooms.timeline(id) : null;
    if (timeline == null) {
      showToast(context, messageUnavailable);
      return;
    }
    setState(() => _goTo(id));
    _scaffoldKey.currentState?.closeDrawer();
    timeline.jumpTo(route.eventId);
  }
```

In `_goTo`, prefer the space on screen when it has the room:

```dart
    final here = !_home && _space.allChannels.any((c) => c.id == id && c.joined);
    final space = here
        ? _spaces.firstWhere((s) => s.id == _placeId)
        : _spaces
              .where((s) => s.allChannels.any((c) => c.id == id && c.joined))
              .firstOrNull;
```

In `_selectChannel`, inside the `setState` after `_open(_placeId, id);`:

```dart
      // A conversation left back in history opens at its newest again:
      // choosing a channel is asking for what is happening there now.
      if (channel.kind != ChannelKind.voice && _can(RoomAbility.messages)) {
        _rooms.timeline(id)?.showNewest();
      }
```

- [ ] **Step 4: Run the shell tests**

Run: `mise exec -- flutter test test/app_shell_rooms_test.dart test/app_shell_test.dart test/app_shell_real_session_test.dart test/space_actions_test.dart`
Expected: PASS.

- [ ] **Step 5: Amend the spec**

In `docs/superpowers/specs/2026-10-06-notifications-design.md`, replace the body of "## B. Jump to message" with:

```markdown
A `MessageRoute(roomId, eventId)` (not `Route`, which Flutter already
exports) selects the room's space (Home for DMs and rooms outside spaces;
the space you are in when it has the room) and opens the channel. The
timeline loads around the event with `eventContextId`, scrolls it into
view, and highlights it briefly. Scrolling down from there loads forward to
the live end. Sending from back in history returns to the newest messages
first; reacting, editing or deleting catches up to live in place.

An event the server won't return opens the channel at its newest messages
with a toast saying the message isn't available. A route to a room you
aren't in shows the same toast and stays where you are: there is no
channel to open. A route that arrives before the first sync waits for it.

Tapping a reply's quote jumps to the message it answers, the same way.
```

In section D, change `Stream<Route> get clicks;` to `Stream<MessageRoute> get clicks;`. In the same section and in E, change "the route" wording only where it names the type.

- [ ] **Step 6: Commit**

```bash
git add lib/ui/shell/app_shell.dart test/app_shell_rooms_test.dart docs/superpowers/specs/2026-10-06-notifications-design.md
git commit -m "feat(jump): the shell follows a route to its room and message"
```

---

### Task 6: Whole suite, analysis, formatting

**Files:** none new.

- [ ] **Step 1: Format**

Run: `mise exec -- dart format lib test`
Expected: only files this branch touched change, if any.

- [ ] **Step 2: Analyze**

Run: `mise exec -- flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: Whole suite**

Run: `mise exec -- flutter test`
Expected: all pass. That's 1445 plus this branch's new tests, with none skipped that weren't skipped before.

- [ ] **Step 4: Commit any formatting**

```bash
git add -A lib test
git commit -m "style: format"
```

(Skip if nothing changed. Never add `tmpl_plugin/`.)

---

## By hand (after review, before merge)

Run on macOS against Chris's account. First check `pgrep -fl "Loaf Chat"`: if the installed copy is running, ask Chris to quit it (memory: `debug-build-shares-data`).

1. In a room with history, scroll up to a reply whose original is loaded and tap its quote. It scrolls there and glows.
2. Find a reply to something far back (quote reads "a message further up"). Tap it. The conversation reopens around it, centred and lit. Scroll down: "loading newer messages" appears at the bottom and pages arrive until live, while the message you're reading stays where it is.
3. While back in history, react to the old message. It catches up and the reaction shows. Send a message: it returns to the newest messages, and yours is there.
4. Tap the channel's row in the list while back in history. It opens at the newest messages.
