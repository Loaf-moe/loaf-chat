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
    _event(
      'm.room.message',
      {'msgtype': 'm.text', 'body': body},
      sender: sender,
      id: id,
    );

Map<String, Object?> _member(String user, String name) => _event(
  'm.room.member',
  {'membership': 'join', 'displayname': name},
  sender: user,
  stateKey: user,
);

/// [limited] is the first sync's: it replaces what the room had. A later
/// one must not be, or the SDK drops the history already loaded.
Future<void> _sync(
  Client client,
  List<Map<String, Object?>> events, {
  bool limited = false,
}) => client.handleSync(
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
          'timeline': {
            'events': events,
            'prev_batch': 'p0',
            'limited': limited,
          },
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
  await _sync(client, [
    _text('now 1', id: r'$now1'),
    _text('now 2'),
  ], limited: true);
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

  test(
    'a message that is gone, from back in history, opens the newest',
    () async {
      final h = await _open();
      h.api.contexts[r'$old'] = _context(r'$old', 'the old one');
      h.timeline.jumpTo(r'$old');
      await _until(() => h.timeline.jumpTarget != null);
      h.timeline.jumpShown();

      h.timeline.jumpTo(r'$gone');
      await _until(() => !h.timeline.canLoadNewer);
      expect(h.bodies, ['now 1', 'now 2']);
      expect(h.timeline.jumpTarget, isNull);
    },
  );

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

  test(
    'reacting while back in history catches up, keeping the message',
    () async {
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
        _event(
          'm.reaction',
          {
            'm.relates_to': {
              'rel_type': 'm.annotation',
              'event_id': r'$old',
              'key': '👍',
            },
          },
          sender: _me,
          id: r'$sent0',
        ),
      ]);
      await _settle();
      final old = h.timeline.messages.firstWhere((m) => m.id == r'$old');
      expect(old.reactions.single.emoji, '👍');
    },
  );
}
