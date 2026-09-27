import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_rooms.dart';
import 'package:loaf_native/matrix/matrix_timeline.dart';
import 'package:loaf_native/ui/model/models.dart' hide Role;
import 'package:matrix/matrix.dart' hide Timeline;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';
const _ada = '@ada:example.com';
const _roomId = '!talk:example.com';

/// The fake server, plus what a conversation needs of it: sending,
/// redacting, read markers and history, for [_roomId]. Each can be made to
/// fail, and history can be held back.
class _Api extends FakeMatrixApi {
  final sent = <(String, Map<String, Object?>)>[];
  final redacted = <String>[];
  final markers = <Map<String, Object?>>[];
  var refuseSend = false;

  /// Answers sends with a server error rather than a refusal: the SDK marks
  /// the echo failed but, unlike a 403, does not throw.
  var failSend = false;
  var refuseRedact = false;
  var refuseHistory = false;
  Completer<void>? holdMarkers;
  Completer<void>? holdSend;

  /// What each history request answers with, in turn.
  final history = <Map<String, Object?>>[];

  var _ids = 0;

  static http.Response _json(Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status);

  static final _forbidden = _json({
    'errcode': 'M_FORBIDDEN',
    'error': 'not allowed',
  }, 403);

  static final _serverError = _json({
    'errcode': 'M_UNKNOWN',
    'error': 'something broke',
  }, 500);

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final path = Uri.decodeComponent(request.url.path);
    if (!path.contains('/rooms/$_roomId/')) {
      return super.mockIntercept(request);
    }
    if (request.method == 'PUT' && path.contains('/send/')) {
      await holdSend?.future;
      if (refuseSend) return _forbidden;
      if (failSend) return _serverError;
      final type = path.split('/send/').last.split('/').first;
      sent.add((type, jsonDecode(request.body) as Map<String, Object?>));
      return _json({'event_id': '\$sent${_ids++}'});
    }
    if (request.method == 'PUT' && path.contains('/redact/')) {
      if (refuseRedact) return _forbidden;
      redacted.add(path.split('/redact/').last.split('/').first);
      return _json({'event_id': '\$redaction${_ids++}'});
    }
    if (request.method == 'POST' && path.endsWith('/read_markers')) {
      markers.add(jsonDecode(request.body) as Map<String, Object?>);
      await holdMarkers?.future;
      return _json({});
    }
    if (request.method == 'GET' && path.endsWith('/messages')) {
      if (refuseHistory) return _forbidden;
      return _json(history.removeAt(0));
    }
    return super.mockIntercept(request);
  }
}

Future<Client> _client(_Api api, {String path = inMemoryDatabasePath}) async {
  final client = await openClient(httpClient: api, databasePath: path);
  FakeMatrixApi.client = client;
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse('https://fakeServer.notExisting'),
    newUserID: _me,
    newDeviceID: 'GHTYAJCE',
    newDeviceName: 'loaf on test',
    waitForFirstSync: false,
  );
  return client;
}

/// Lets the SDK's streams and the fake server deliver.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

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

Map<String, Object?> _text(
  String body, {
  String sender = _ada,
  String? id,
  String msgtype = 'm.text',
  String? replyTo,
}) => _event(
  'm.room.message',
  {
    'msgtype': msgtype,
    'body': body,
    if (replyTo != null)
      'm.relates_to': {
        'm.in_reply_to': {'event_id': replyTo},
      },
  },
  sender: sender,
  id: id,
);

Map<String, Object?> _edit(String of, String body, {String sender = _ada}) =>
    _event('m.room.message', {
      'msgtype': 'm.text',
      'body': '* $body',
      'm.new_content': {'msgtype': 'm.text', 'body': body},
      'm.relates_to': {'rel_type': 'm.replace', 'event_id': of},
    }, sender: sender);

Map<String, Object?> _reaction(
  String of,
  String key, {
  String sender = _ada,
  String? id,
}) => _event(
  'm.reaction',
  {
    'm.relates_to': {'rel_type': 'm.annotation', 'event_id': of, 'key': key},
  },
  sender: sender,
  id: id,
);

Map<String, Object?> _member(String user, String name) => _event(
  'm.room.member',
  {'membership': 'join', 'displayname': name},
  sender: user,
  stateKey: user,
);

/// Joins [_roomId], with Ada in it, and delivers [events] on its timeline.
/// [prevBatch] leaves history further back; [encrypted] turns encryption on.
Future<void> _sync(
  Client client,
  List<Map<String, Object?>> events, {
  String? prevBatch,
  bool encrypted = false,
  int notifications = 0,
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
              if (encrypted)
                _event('m.room.encryption', {
                  'algorithm': 'm.megolm.v1.aes-sha2',
                }, stateKey: ''),
            ],
          },
          'timeline': {
            'events': events,
            'prev_batch': ?prevBatch,
            'limited': prevBatch != null,
          },
          'unread_notifications': {'notification_count': notifications},
        },
      },
    },
  }),
);

class _Harness {
  _Harness(this.api, this.client, this.rooms);
  final _Api api;
  final Client client;
  final MatrixRooms rooms;

  MatrixTimeline get timeline => rooms.timeline(_roomId)! as MatrixTimeline;
  List<Message> get messages => timeline.messages;
  Message byBody(String body) => messages.firstWhere((m) => m.body == body);
}

/// A signed-in client whose room has [events], and its timeline opened.
Future<_Harness> _open(
  List<Map<String, Object?>> events, {
  String? prevBatch,
  bool encrypted = false,
}) async {
  final api = _Api();
  final client = await _client(api);
  addTearDown(client.dispose);
  await _sync(client, events, prevBatch: prevBatch, encrypted: encrypted);
  final rooms = MatrixRooms(client);
  addTearDown(rooms.dispose);
  final h = _Harness(api, client, rooms);
  h.timeline; // Opens it.
  await _settle();
  return h;
}

void main() {
  test('each room has one conversation, the same each time', () async {
    final h = await _open([_text('hello')]);
    expect(h.timeline, same(h.rooms.timeline(_roomId)));
    expect(h.rooms.timeline('!nowhere:example.com'), isNull);
  });

  group('mapping', () {
    test('text, notices and emotes are rows, oldest first', () async {
      final h = await _open([
        _text('first'),
        _text('a notice', msgtype: 'm.notice'),
        _text('waves', msgtype: 'm.emote'),
      ]);
      expect(h.messages.map((m) => m.body), ['first', 'a notice', 'Ada waves']);
      final first = h.messages.first;
      expect(first.author.id, _ada);
      expect(first.author.name, 'Ada');
      expect(first.status, MessageStatus.sent);
      expect(first.locked, isFalse);
    });

    test('a file is a plain row until media is drawn', () async {
      final h = await _open([
        _event('m.room.message', {
          'msgtype': 'm.file',
          'body': 'recipe.pdf',
          'url': 'mxc://example.com/abc',
        }),
      ]);
      expect(h.messages.single.body, '📎 recipe.pdf');
    });

    test('state events are not rows', () async {
      final h = await _open([
        _event('m.room.topic', {'topic': 'bread'}, stateKey: ''),
        _text('after'),
      ]);
      expect(h.messages.map((m) => m.body), ['after']);
    });

    test('an edit by the author changes the text and marks it', () async {
      final h = await _open([
        _text('helo', id: r'$m1'),
        _edit(r'$m1', 'hello'),
      ]);
      final m = h.messages.single;
      expect(m.id, r'$m1');
      expect(m.body, 'hello');
      expect(m.edited, isTrue);
    });

    test('an edit by anyone else is ignored', () async {
      final h = await _open([
        _text('mine', id: r'$m1'),
        _edit(r'$m1', 'hijacked', sender: '@mallory:example.com'),
      ]);
      final m = h.messages.single;
      expect(m.body, 'mine');
      expect(m.edited, isFalse);
    });

    test('reactions count each person once, and know yours', () async {
      final h = await _open([
        _text('bread', id: r'$m1'),
        _reaction(r'$m1', '🔥'),
        _reaction(r'$m1', '🔥', sender: _me),
        _reaction(r'$m1', '🥖'),
      ]);
      final reactions = {
        for (final r in h.messages.single.reactions) r.emoji: r,
      };
      expect(reactions['🔥']!.count, 2);
      expect(reactions['🔥']!.mine, isTrue);
      expect(reactions['🥖']!.count, 1);
      expect(reactions['🥖']!.mine, isFalse);
    });

    test('a taken-back reaction is gone', () async {
      final h = await _open([
        _text('bread', id: r'$m1'),
        _reaction(r'$m1', '🔥', id: r'$r1'),
        _event('m.room.redaction', {}, id: r'$x1')..['redacts'] = r'$r1',
      ]);
      expect(h.messages.single.reactions, isEmpty);
    });

    test('a reply quotes what it answers, loaded or not', () async {
      final h = await _open([
        _text('question', id: r'$q', sender: _me),
        _text('answer', replyTo: r'$q'),
        _text('late answer', replyTo: r'$long-gone'),
      ]);
      final answer = h.byBody('answer');
      expect(answer.replyTo!.body, 'question');
      expect(answer.replyTo!.author.id, _me);
      expect(answer.replyTo!.replyTo, isNull);
      final late = h.byBody('late answer');
      expect(late.replyTo!.stub, isTrue);
      expect(late.replyTo!.author.name, 'someone');
    });

    test('a reply quotes what it answers as last edited', () async {
      final h = await _open([
        _text('helo', id: r'$q'),
        _edit(r'$q', 'hello'),
        _text('hi back', replyTo: r'$q', sender: _me),
      ]);
      expect(h.byBody('hi back').replyTo!.body, 'hello');
    });

    test('the reply fallback is not part of the text', () async {
      final h = await _open([
        _text('question', id: r'$q'),
        _event('m.room.message', {
          'msgtype': 'm.text',
          'body': '> <@ada:example.com> question\n\nanswer',
          'm.relates_to': {
            'm.in_reply_to': {'event_id': r'$q'},
          },
        }),
      ]);
      expect(h.messages.last.body, 'answer');
    });

    test(
      'a deleted message is gone, and a reply to it quotes a stub',
      () async {
        final h = await _open([
          _text('oops', id: r'$m1'),
          _text('what was that?', replyTo: r'$m1', sender: _me),
          _event('m.room.redaction', {}, id: r'$x1')..['redacts'] = r'$m1',
        ]);
        expect(h.messages.map((m) => m.body), ['what was that?']);
        final quote = h.messages.single.replyTo!;
        expect(quote.stub, isTrue);
        expect(quote.author.name, 'Ada');
      },
    );

    test('an encrypted room locks what it cannot read, and is not '
        'writable', () async {
      final h = await _open([
        _event('m.room.encrypted', {
          'algorithm': 'm.megolm.v1.aes-sha2',
          'ciphertext': 'AwgA',
          'sender_key': 'k',
          'session_id': 's',
          'device_id': 'D',
        }),
      ], encrypted: true);
      final m = h.messages.single;
      expect(m.locked, isTrue);
      expect(m.author.name, 'Ada');
      expect(h.timeline.writable, isFalse);
    });

    test('an unencrypted room is writable', () async {
      final h = await _open([_text('hi')]);
      expect(h.timeline.writable, isTrue);
    });

    test('a new message arriving is heard', () async {
      final h = await _open([_text('one')]);
      var heard = 0;
      h.timeline.addListener(() => heard++);
      await _sync(h.client, [_text('two')]);
      await _settle();
      expect(h.messages.map((m) => m.body), ['one', 'two']);
      expect(heard, greaterThan(0));
    });
  });

  group('sending', () {
    test('a message shows at once as sending, then as sent', () async {
      final h = await _open([_text('hi')]);
      final api = h.api..holdSend = Completer<void>();
      h.timeline.send('  fresh bread  ');
      // The echo lands before the server has answered.
      await _settle();
      final echo = h.messages.last;
      expect(echo.body, 'fresh bread');
      expect(echo.author.id, _me);
      expect(echo.status, MessageStatus.sending);
      api.holdSend!.complete();
      await _settle();
      expect(h.messages.last.status, MessageStatus.sent);
      expect(api.sent.single.$1, 'm.room.message');
      expect(api.sent.single.$2['body'], 'fresh bread');
    });

    test('text is sent as written: no commands, no markdown', () async {
      final h = await _open([_text('hi')]);
      h.timeline.send('/leave');
      h.timeline.send('2 * 3 * 4');
      await _settle();
      expect(h.api.sent.map((s) => s.$2['body']), ['/leave', '2 * 3 * 4']);
      expect(h.api.sent.map((s) => s.$2['format']), [null, null]);
      expect(h.client.getRoomById(_roomId)!.membership, Membership.join);
    });

    test('blank text never sends', () async {
      final h = await _open([_text('hi')]);
      h.timeline.send('   ');
      await _settle();
      expect(h.api.sent, isEmpty);
    });

    test('a reply names what it answers, and clears the aim', () async {
      final h = await _open([_text('question', id: r'$q')]);
      h.timeline.startReply(h.byBody('question'));
      h.timeline.send('answer');
      await _settle();
      final content = h.api.sent.single.$2;
      expect((content['m.relates_to']! as Map)['m.in_reply_to'], {
        'event_id': r'$q',
      });
      expect(h.timeline.target, isNull);
      expect(h.byBody('answer').replyTo!.id, r'$q');
    });

    test('a refused message stays, failed, until retried', () async {
      final h = await _open([_text('hi')]);
      h.api.refuseSend = true;
      h.timeline.send('rejected');
      await _settle();
      final failed = h.byBody('rejected');
      expect(failed.status, MessageStatus.failed);

      h.api.refuseSend = false;
      h.timeline.retry(failed.id);
      await _settle();
      expect(h.byBody('rejected').status, MessageStatus.sent);
      expect(h.api.sent.map((s) => s.$2['body']), ['rejected']);
    });

    test('a refused message can be discarded', () async {
      final h = await _open([_text('hi')]);
      h.api.refuseSend = true;
      h.timeline.send('rejected');
      await _settle();
      h.timeline.discard(h.byBody('rejected').id);
      await _settle();
      expect(h.messages.map((m) => m.body), ['hi']);
    });

    test('signing out with a message on its way throws nothing', () async {
      final api = _Api()..holdSend = Completer<void>();
      final client = await _client(api);
      addTearDown(client.dispose);
      await _sync(client, [_text('hi')]);
      final rooms = MatrixRooms(client);
      final timeline = rooms.timeline(_roomId)!;
      await _settle();
      timeline
        ..send('late')
        ..toggleReaction(timeline.messages.first.id, '🔥');
      await _settle();
      rooms.dispose();
      api.holdSend!.complete();
      await _settle();
    });
  });

  group('reacting', () {
    test('toggles your own reaction on and off', () async {
      final h = await _open([_text('bread', id: r'$m1')]);
      h.timeline.toggleReaction(r'$m1', '🔥');
      await _settle();
      expect(h.api.sent.single.$1, 'm.reaction');
      final pill = h.messages.single.reactions.single;
      expect((pill.emoji, pill.count, pill.mine), ('🔥', 1, true));

      h.timeline.toggleReaction(r'$m1', '🔥');
      await _settle();
      expect(h.api.redacted, hasLength(1));
      // Gone once the redaction comes back down a sync.
      await _sync(h.client, [
        _event('m.room.redaction', {}, sender: _me)
          ..['redacts'] = h.api.redacted.single,
      ]);
      await _settle();
      expect(h.messages.single.reactions, isEmpty);
    });

    test('joins someone else\'s pill rather than taking it', () async {
      final h = await _open([
        _text('bread', id: r'$m1'),
        _reaction(r'$m1', '🔥'),
      ]);
      h.timeline.toggleReaction(r'$m1', '🔥');
      await _settle();
      expect(h.api.redacted, isEmpty);
      final pill = h.messages.single.reactions.single;
      expect((pill.count, pill.mine), (2, true));
    });

    test('a second tap before the first reaches the server sends '
        'nothing more', () async {
      final h = await _open([_text('bread', id: r'$m1')]);
      h.api.holdSend = Completer<void>();
      h.timeline
        ..toggleReaction(r'$m1', '🔥')
        ..toggleReaction(r'$m1', '🔥');
      await _settle();
      h.api.holdSend!.complete();
      await _settle();
      expect(h.api.sent, hasLength(1));
      expect(h.api.redacted, isEmpty);
      expect(h.messages.single.reactions.single.mine, isTrue);
    });

    test('a refused reaction snaps back, and says so', () async {
      final h = await _open([_text('bread', id: r'$m1')]);
      final failures = <String>[];
      h.timeline.failures.listen(failures.add);
      h.api.refuseSend = true;
      h.timeline.toggleReaction(r'$m1', '🔥');
      await _settle();
      expect(h.messages.single.reactions, isEmpty);
      expect(failures, ["couldn't react"]);
    });

    test('a reaction the server failed on snaps back, and says so', () async {
      final h = await _open([_text('bread', id: r'$m1')]);
      final failures = <String>[];
      h.timeline.failures.listen(failures.add);
      h.api.failSend = true;
      h.timeline.toggleReaction(r'$m1', '🔥');
      await _settle();
      expect(h.messages.single.reactions, isEmpty);
      expect(failures, ["couldn't react"]);
    });
  });

  group('editing', () {
    test('sends a replacement, which shows as edited', () async {
      final h = await _open([_text('helo', id: r'$m1', sender: _me)]);
      h.timeline.startEdit(h.byBody('helo'));
      h.timeline.saveEdit(r'$m1', 'hello');
      await _settle();
      final content = h.api.sent.single.$2;
      expect(content['m.new_content'], containsPair('body', 'hello'));
      expect(content['m.relates_to'], {
        'rel_type': 'm.replace',
        'event_id': r'$m1',
      });
      expect(h.timeline.target, isNull);
      final m = h.messages.single;
      expect((m.body, m.edited), ('hello', true));
    });

    test('unchanged or blank is not an edit', () async {
      final h = await _open([_text('same', id: r'$m1', sender: _me)]);
      h.timeline.saveEdit(r'$m1', ' same ');
      h.timeline.saveEdit(r'$m1', '   ');
      await _settle();
      expect(h.api.sent, isEmpty);
    });

    test('a refused edit snaps back, and says so', () async {
      final h = await _open([_text('helo', id: r'$m1', sender: _me)]);
      final failures = <String>[];
      h.timeline.failures.listen(failures.add);
      h.api.refuseSend = true;
      h.timeline.saveEdit(r'$m1', 'hello');
      await _settle();
      final m = h.messages.single;
      expect((m.body, m.edited), ('helo', false));
      expect(failures, ["couldn't save that edit"]);
    });

    test('an edit the server failed on snaps back, and says so', () async {
      final h = await _open([_text('helo', id: r'$m1', sender: _me)]);
      final failures = <String>[];
      h.timeline.failures.listen(failures.add);
      h.api.failSend = true;
      h.timeline.saveEdit(r'$m1', 'hello');
      await _settle();
      final m = h.messages.single;
      expect((m.body, m.edited), ('helo', false));
      expect(failures, ["couldn't save that edit"]);
    });
  });

  group('deleting', () {
    test('redacts, and the message goes when that syncs back', () async {
      final h = await _open([_text('oops', id: r'$m1', sender: _me)]);
      h.timeline.delete(r'$m1');
      await _settle();
      expect(h.api.redacted, [r'$m1']);
      await _sync(h.client, [
        _event('m.room.redaction', {}, sender: _me)..['redacts'] = r'$m1',
      ]);
      await _settle();
      expect(h.messages, isEmpty);
    });

    test('a refused delete leaves the message, and says so', () async {
      final h = await _open([_text('oops', id: r'$m1', sender: _me)]);
      final failures = <String>[];
      h.timeline.failures.listen(failures.add);
      h.api.refuseRedact = true;
      h.timeline.delete(r'$m1');
      await _settle();
      expect(h.messages.single.body, 'oops');
      expect(failures, ["couldn't delete that"]);
    });
  });

  group('history', () {
    /// One page from the server, newest first, reaching the room's start.
    Map<String, Object?> page() => {
      'chunk': [
        _text('older'),
        _text('oldest'),
        _event('m.room.create', {'creator': _me}, stateKey: ''),
      ],
      'start': 'p1',
      'end': 'p0',
    };

    test('pages back to the room\'s start, and then stops', () async {
      final h = await _open([_text('recent')], prevBatch: 'p1');
      h.api.history.add(page());
      expect(h.timeline.loadingOlder, isFalse);
      expect(h.timeline.canLoadOlder, isTrue);
      h.timeline.loadOlder();
      expect(h.timeline.loadingOlder, isTrue);
      await _settle();
      expect(h.timeline.loadingOlder, isFalse);
      expect(h.messages.map((m) => m.body), ['oldest', 'older', 'recent']);
      expect(h.timeline.canLoadOlder, isFalse);
    });

    test('history that ends in an empty page stops asking', () async {
      final h = await _open([_text('recent')], prevBatch: 'p1');
      // No create event and no `end`: the server has nothing further.
      h.api.history.add({'chunk': [], 'start': 'p1'});
      h.timeline.loadOlder();
      await _settle();
      expect(h.timeline.canLoadOlder, isFalse);
      h.timeline.loadOlder();
      await _settle();
      expect(h.api.history, isEmpty);
    });

    test('a failed page can be tried again', () async {
      final h = await _open([_text('recent')], prevBatch: 'p1');
      h.api.refuseHistory = true;
      h.timeline.loadOlder();
      await _settle();
      expect(h.timeline.loadOlderFailed, isTrue);
      expect(h.timeline.loadingOlder, isFalse);

      h.api
        ..refuseHistory = false
        ..history.add(page());
      h.timeline.loadOlder();
      await _settle();
      expect(h.timeline.loadOlderFailed, isFalse);
      expect(h.messages.first.body, 'oldest');
    });

    test('is loading while the timeline opens', () async {
      final api = _Api();
      final client = await _client(api);
      addTearDown(client.dispose);
      await _sync(client, [_text('hi')]);
      final rooms = MatrixRooms(client);
      addTearDown(rooms.dispose);
      final timeline = rooms.timeline(_roomId)!;
      expect(timeline.loadingOlder, isTrue);
      expect(timeline.messages, isEmpty);
      await _settle();
      expect(timeline.loadingOlder, isFalse);
      expect(timeline.messages.single.body, 'hi');
    });
  });

  group('marking read', () {
    test(
      'sets the fully-read marker and receipt on the newest event',
      () async {
        final h = await _open([_text('one'), _text('two', id: r'$last')]);
        h.rooms.markRead(_roomId);
        await _settle();
        final marker = h.api.markers.single;
        expect(marker['m.fully_read'], r'$last');
        // Public: the person you are talking to sees you have read it.
        expect(marker['m.read'], r'$last');
      },
    );

    test('a burst sends one receipt at a time, ending on the newest', () async {
      final h = await _open([_text('one', id: r'$1')]);
      h.api.holdMarkers = Completer<void>();
      h.rooms.markRead(_roomId);
      await _settle();
      await _sync(h.client, [_text('two', id: r'$2')]);
      h.rooms
        ..markRead(_roomId)
        ..markRead(_roomId);
      await _settle();
      expect(h.api.markers, hasLength(1));
      h.api.holdMarkers!.complete();
      await _settle();
      expect(h.api.markers.map((m) => m['m.fully_read']), [r'$1', r'$2']);
    });

    test('a room already read sends nothing', () async {
      final api = _Api();
      final client = await _client(api);
      addTearDown(client.dispose);
      await _sync(client, [_text('one', id: r'$1')]);
      await client.handleSync(
        SyncUpdate.fromJson({
          'next_batch': 'b${_n++}',
          'rooms': {
            'join': {
              _roomId: {
                'account_data': {
                  'events': [
                    {
                      'type': 'm.fully_read',
                      'content': {'event_id': r'$1'},
                    },
                  ],
                },
              },
            },
          },
        }),
      );
      final rooms = MatrixRooms(client);
      addTearDown(rooms.dispose);
      rooms.markRead(_roomId);
      await _settle();
      expect(api.markers, isEmpty);
    });

    test('your own message on its way is not marked', () async {
      final h = await _open([_text('one', id: r'$1')]);
      h.api.holdSend = Completer<void>();
      h.timeline.send('mine');
      await _settle();
      h.rooms.markRead(_roomId);
      await _settle();
      expect(h.api.markers, isEmpty);
      h.api.holdSend!.complete();
    });
  });

  test('after a relaunch, the conversation and a failed message come '
      'back', () async {
    final dir = await Directory.systemTemp.createTemp('loaf_timeline');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/loaf.sqlite';

    final api = _Api()..refuseSend = true;
    final first = await _client(api, path: path);
    await _sync(first, [_text('kept')]);
    final firstRooms = MatrixRooms(first);
    firstRooms.timeline(_roomId)!;
    await _settle();
    firstRooms.timeline(_roomId)!.send('unsent');
    await _settle();
    expect(
      firstRooms.timeline(_roomId)!.messages.last.status,
      MessageStatus.failed,
    );
    firstRooms.dispose();
    await first.dispose(closeDatabase: true);

    // The app opens again: everything comes back from the database.
    final client = await openClient(httpClient: _Api(), databasePath: path);
    FakeMatrixApi.client = client;
    await client.init(waitForFirstSync: false);
    addTearDown(() => client.dispose(closeDatabase: true));
    final rooms = MatrixRooms(client);
    addTearDown(rooms.dispose);
    final timeline = rooms.timeline(_roomId)!;
    await _settle();
    expect(timeline.messages.map((m) => (m.body, m.status)), [
      ('kept', MessageStatus.sent),
      ('unsent', MessageStatus.failed),
    ]);
  });

  test('a message on its way when the app quit comes back failed, and '
      'retries', () async {
    final dir = await Directory.systemTemp.createTemp('loaf_timeline');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/loaf.sqlite';

    // The server never answers before the app quits.
    final first = await _client(
      _Api()..holdSend = Completer<void>(),
      path: path,
    );
    await _sync(first, [_text('kept')]);
    final firstRooms = MatrixRooms(first);
    firstRooms.timeline(_roomId)!;
    await _settle();
    firstRooms.timeline(_roomId)!.send('in flight');
    await _settle();
    expect(
      firstRooms.timeline(_roomId)!.messages.last.status,
      MessageStatus.sending,
    );
    firstRooms.dispose();
    await first.dispose(closeDatabase: true);

    final api = _Api();
    final client = await openClient(httpClient: api, databasePath: path);
    FakeMatrixApi.client = client;
    await client.init(waitForFirstSync: false);
    addTearDown(() => client.dispose(closeDatabase: true));
    final rooms = MatrixRooms(client);
    addTearDown(rooms.dispose);
    final timeline = rooms.timeline(_roomId)!;
    await _settle();
    final stranded = timeline.messages.last;
    expect(
      (stranded.body, stranded.status),
      ('in flight', MessageStatus.failed),
    );

    timeline.retry(stranded.id);
    await _settle();
    expect(timeline.messages.last.status, MessageStatus.sent);
    expect(api.sent.single.$2['body'], 'in flight');
  });
}
