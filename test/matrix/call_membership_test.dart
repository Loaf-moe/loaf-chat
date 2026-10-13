import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/call_members.dart';
import 'package:loaf_native/matrix/call_membership.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';
const _device = 'GHTYAJCE';
const _room = '!oven:example.com';
const _minute = 60000;

/// The expiry the quick timings keep: the default.
const _expiry = 10 * _minute;
final _server = Uri.parse('https://calls.example.com');
final _noon = DateTime.utc(2026, 10, 11, 12);

/// Short enough to wait out: a refresh every 200 ms less 50, a retry after
/// 100, and leaving tried again after 20.
const _quick = CallMembershipTimings(
  refreshEvery: Duration(milliseconds: 200),
  headroom: Duration(milliseconds: 50),
  retryRefreshIn: Duration(milliseconds: 100),
  retryLeaveIn: Duration(milliseconds: 20),
);

/// One write of the membership: where it went and what it said.
typedef _Write = ({String stateKey, Map<String, Object?> content});

/// The fake homeserver, keeping every write of a call membership and
/// answering them as [answers] says, in order, then with success.
class _Api extends FakeMatrixApi {
  final writes = <_Write>[];

  /// Answers for the writes to come. A null is a dropped connection.
  final answers = <http.Response?>[];

  /// Held back until completed, when set: the answer to the next write.
  Completer<void>? hold;

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    const marker = '/state/$callMemberType/';
    final path = request.url.path;
    if (request.method == 'PUT' && path.contains(marker)) {
      writes.add((
        stateKey: Uri.decodeComponent(path.split(marker)[1]),
        content: jsonDecode(request.body) as Map<String, Object?>,
      ));
      final held = hold;
      hold = null;
      await held?.future;
      if (answers.isEmpty) {
        return http.Response(
          jsonEncode({'event_id': '\$w${writes.length}'}),
          200,
        );
      }
      final answer = answers.removeAt(0);
      if (answer == null) throw http.ClientException('connection dropped');
      return answer;
    }
    return super.mockIntercept(request);
  }
}

http.Response _refused() => http.Response(
  jsonEncode({'errcode': 'M_FORBIDDEN', 'error': 'not allowed'}),
  403,
);

var _events = 0;

Future<(Client, Room)> _joined(_Api api, {String? roomVersion}) async {
  final client = await openClient(
    httpClient: api,
    databasePath: inMemoryDatabasePath,
  );
  addTearDown(client.dispose);
  FakeMatrixApi.client = client;
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse('https://fakeServer.notExisting'),
    newUserID: _me,
    newDeviceID: _device,
    newDeviceName: 'loaf on test',
  );
  await _sync(client, [
    {
      'type': 'm.room.create',
      'state_key': '',
      'sender': _me,
      'content': {'creator': _me, 'room_version': ?roomVersion},
      'event_id': '\$e${_events++}',
      'origin_server_ts': 1700000000000,
    },
    {
      'type': 'm.room.member',
      'state_key': _me,
      'sender': _me,
      'content': {'membership': 'join'},
      'event_id': '\$e${_events++}',
      'origin_server_ts': 1700000000000,
    },
  ]);
  return (client, client.getRoomById(_room)!);
}

Future<void> _sync(Client client, List<Map<String, Object?>> state) =>
    client.handleSync(
      SyncUpdate.fromJson({
        'next_batch': 'b${_events++}',
        'rooms': {
          'join': {
            _room: {
              'state': {'events': state},
            },
          },
        },
      }),
    );

OwnCallMembership _membership(
  Client client,
  Room room, {
  void Function()? onLost,
  DateTime Function()? now,
}) {
  final membership = OwnCallMembership(
    client,
    room,
    _server,
    now: now ?? () => _noon,
    timings: _quick,
    onLost: onLost,
  );
  addTearDown(membership.dispose);
  return membership;
}

Future<void> _until(bool Function() done) async {
  final give = DateTime.now().add(const Duration(seconds: 10));
  while (!done() && DateTime.now().isBefore(give)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('joining writes the membership Element Call reads', () async {
    final api = _Api();
    final (client, room) = await _joined(api);

    await _membership(client, room).join();

    expect(api.writes.single.content, {
      'application': 'm.call',
      'call_id': '',
      'scope': 'm.room',
      'device_id': _device,
      'membershipID': '$_me:$_device',
      'expires': 10 * _minute,
      'm.call.intent': 'audio',
      'focus_active': {'type': 'livekit', 'focus_selection': 'multi_sfu'},
      'foci_preferred': [
        {
          'type': 'livekit',
          'livekit_service_url': 'https://calls.example.com',
          'livekit_alias': _room,
        },
      ],
    });
  });

  test(
    'the membership is keyed by user and device, behind an underscore',
    () async {
      final api = _Api();
      final (client, room) = await _joined(api, roomVersion: '11');

      await _membership(client, room).join();

      expect(api.writes.single.stateKey, '_${_me}_${_device}_m.call');
    },
  );

  for (final version in ['org.matrix.msc3757.11', 'org.matrix.msc3779.10']) {
    test('a $version room keys it without the underscore', () async {
      final api = _Api();
      final (client, room) = await _joined(api, roomVersion: version);

      await _membership(client, room).join();

      expect(api.writes.single.stateKey, '${_me}_${_device}_m.call');
    });
  }

  test('the next refresh comes five seconds short of five minutes on', () {
    expect(
      const CallMembershipTimings().refreshAfter,
      const Duration(minutes: 4, seconds: 55),
    );
  });

  test('a refresh expires ten minutes after the moment it is written, '
      'however late that is', () async {
    final api = _Api();
    final (client, room) = await _joined(api);
    var clock = _noon;

    await _membership(client, room, now: () => clock).join();
    clock = _noon.add(const Duration(minutes: 7));
    await _until(() => api.writes.length >= 2);

    expect(api.writes[1].content['expires'], 7 * _minute + _expiry);
  });

  test('refreshes keep their pace when the clock leaps ahead', () async {
    final api = _Api();
    final (client, room) = await _joined(api);
    var clock = _noon;

    await _membership(client, room, now: () => clock).join();
    clock = _noon.add(const Duration(hours: 2));
    // Three refreshes' worth, at one every 150 ms.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(api.writes.length, inInclusiveRange(3, 5));
  });

  test(
    'a refresh says when the membership began, as the server has it',
    () async {
      final api = _Api();
      final (client, room) = await _joined(api);
      final membership = _membership(client, room);

      await membership.join();
      await _sync(client, [
        {
          'type': callMemberType,
          'state_key': membership.stateKey,
          'sender': _me,
          'content': api.writes.single.content,
          'event_id': '\$e${_events++}',
          'origin_server_ts': 1790000000000,
        },
      ]);
      await _until(() => api.writes.length >= 2);

      expect(api.writes[1].content['created_ts'], 1790000000000);
    },
  );

  test('a refresh the server has not echoed says when you joined', () async {
    final api = _Api();
    final (client, room) = await _joined(api);

    await _membership(client, room).join();
    await _until(() => api.writes.length >= 2);

    expect(api.writes[1].content['created_ts'], _noon.millisecondsSinceEpoch);
  });

  test('the first write names no beginning', () async {
    final api = _Api();
    final (client, room) = await _joined(api);

    await _membership(client, room).join();

    expect(api.writes.single.content.containsKey('created_ts'), isFalse);
  });

  group('a refresh is tried again after', () {
    final failures = <String, http.Response?>{
      'a dropped connection': null,
      'a server fault': http.Response('oops', 502),
      'being told to slow down': http.Response(
        jsonEncode({'errcode': 'M_LIMIT_EXCEEDED', 'error': 'slow down'}),
        429,
      ),
    };
    for (final MapEntry(key: name, value: failure) in failures.entries) {
      test(name, () async {
        final api = _Api();
        final (client, room) = await _joined(api);

        await _membership(client, room).join();
        api.answers.add(failure);
        await _until(() => api.writes.length >= 3);

        expect(api.writes[2].content['expires'], _expiry);
      });
    }
  });

  test('a refused refresh reports the membership lost and stops', () async {
    final api = _Api();
    final (client, room) = await _joined(api);
    var lost = 0;

    await _membership(client, room, onLost: () => lost++).join();
    api.answers.add(_refused());
    await _until(() => lost > 0);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(lost, 1);
    expect(api.writes, hasLength(2));
  });

  test('a refused join throws, and nothing is refreshed', () async {
    final api = _Api()..answers.add(_refused());
    final (client, room) = await _joined(api);

    await expectLater(
      _membership(client, room).join(),
      throwsA(isA<MatrixException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(api.writes, hasLength(1));
  });

  test('leaving writes an empty membership under the same key', () async {
    final api = _Api();
    final (client, room) = await _joined(api);
    final membership = _membership(client, room);

    await membership.join();
    await membership.leave();

    expect(api.writes.last.stateKey, membership.stateKey);
    expect(api.writes.last.content, isEmpty);
  });

  test('nothing is refreshed after leaving', () async {
    final api = _Api();
    final (client, room) = await _joined(api);
    final membership = _membership(client, room);

    await membership.join();
    await membership.leave();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(api.writes, hasLength(2));
  });

  test('leaving through a dropped connection is tried three times', () async {
    final api = _Api();
    final (client, room) = await _joined(api);
    final membership = _membership(client, room);

    await membership.join();
    api.answers.addAll([null, null, null, null]);
    await membership.leave();

    expect([
      for (final write in api.writes.skip(1)) write.content,
    ], List.filled(3, <String, Object?>{}));
  });

  test(
    'leaving waits for a refresh in flight, so its own write lands last',
    () async {
      final api = _Api();
      final (client, room) = await _joined(api);
      final membership = _membership(client, room);
      await membership.join();
      final refresh = api.hold = Completer();
      await _until(() => api.writes.length == 2);

      final left = membership.leave();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sentWhileWaiting = api.writes.length;
      refresh.complete();
      await left;

      expect(sentWhileWaiting, 2);
      expect(api.writes.last.content, isEmpty);
    },
  );

  test('a join whose answer was lost is emptied on leaving', () async {
    final api = _Api()..answers.add(null);
    final (client, room) = await _joined(api);
    final membership = _membership(client, room);
    await expectLater(membership.join(), throwsA(isA<http.ClientException>()));

    await membership.leave();

    expect(api.writes, hasLength(2));
    expect(api.writes.last.content, isEmpty);
  });

  test('a refused join leaves nothing to empty', () async {
    final api = _Api()..answers.add(_refused());
    final (client, room) = await _joined(api);
    final membership = _membership(client, room);
    await expectLater(membership.join(), throwsA(isA<MatrixException>()));

    await membership.leave();

    expect(api.writes, hasLength(1));
  });

  test('leaving when told to slow down is tried again', () async {
    final api = _Api();
    final (client, room) = await _joined(api);
    final membership = _membership(client, room);
    await membership.join();
    api.answers.add(
      http.Response(
        jsonEncode({'errcode': 'M_LIMIT_EXCEEDED', 'error': 'slow down'}),
        429,
      ),
    );

    await membership.leave();

    expect([
      for (final write in api.writes.skip(1)) write.content,
    ], List.filled(2, isEmpty));
  });

  test('leaving before joining writes nothing', () async {
    final api = _Api();
    final (client, room) = await _joined(api);

    await _membership(client, room).leave();

    expect(api.writes, isEmpty);
  });
}
