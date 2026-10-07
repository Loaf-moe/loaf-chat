import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/matrix_unread.dart';
import 'package:matrix/matrix.dart';

import 'crypto_harness.dart';

const _room = '!secret:example.com';
var _n = 0;

/// Puts both of you in [_room], encrypted, and delivers [events] on its
/// timeline.
Future<void> _sync(
  Client client, [
  List<Map<String, Object?>> events = const [],
]) => client.handleSync(
  SyncUpdate.fromJson({
    'next_batch': 'b${_n++}',
    'rooms': {
      'join': {
        _room: {
          'state': {
            'events': [
              for (final (type, key, content) in [
                ('m.room.create', '', {'creator': me}),
                ('m.room.member', me, {'membership': 'join'}),
                ('m.room.member', other, {'membership': 'join'}),
                (
                  'm.room.encryption',
                  '',
                  {'algorithm': 'm.megolm.v1.aes-sha2'},
                ),
              ])
                {
                  'type': type,
                  'state_key': key,
                  'sender': me,
                  'content': content,
                  'event_id': '\$s${_n++}',
                  'origin_server_ts': 1700000000000,
                },
            ],
          },
          'timeline': {'events': events},
        },
      },
    },
  }),
);

void main() {
  test(
    'a locked message that mentions you counts once its key arrives',
    () async {
      final mine = await cryptoClient();
      final theirs = await cryptoClient(
        api: FakeMatrixApi.currentApi,
        asOther: true,
      );
      await theirs.updateUserDeviceKeys(additionalUsers: {me});
      await _sync(theirs);
      await _sync(mine);
      final sealed = await theirs.encryption!.encryptGroupMessagePayload(
        _room,
        {
          'msgtype': 'm.text',
          'body': 'hey',
          'm.mentions': {
            'user_ids': [me],
          },
        },
      );

      var changes = 0;
      final unread = MatrixUnread(mine, onChange: () => changes++);
      addTearDown(unread.dispose);
      // What MatrixRooms does with each sync.
      final sub = mine.onSync.stream.listen(unread.apply);
      addTearDown(sub.cancel);

      await _sync(mine, [
        {
          'type': EventTypes.Encrypted,
          'sender': other,
          'content': sealed,
          'event_id': r'$sealed',
          'origin_server_ts': 1700000001000,
        },
      ]);
      // Lets the SDK's stream deliver the sync.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await unread.idle;
      expect(unread.of(_room).count, 1);
      expect(unread.of(_room).mentions, 0);
      expect(unread.of(_room).entries.single.locked, isTrue);

      // As a forwarded key, or key backup, would bring it.
      final sessionId = sealed['session_id'] as String;
      final key = theirs.encryption!.keyManager
          .getInboundGroupSession(_room, sessionId)!
          .inboundGroupSession!
          .exportAtFirstKnownIndex();
      final before = changes;
      await mine.encryption!.keyManager.setInboundGroupSession(
        _room,
        sessionId,
        theirs.identityKey,
        {
          'algorithm': AlgorithmTypes.megolmV1AesSha2,
          'room_id': _room,
          'session_id': sessionId,
          'session_key': key,
        },
        forwarded: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await unread.idle;
      expect(unread.of(_room).mentions, 1);
      expect(unread.of(_room).entries.single.locked, isFalse);
      expect(changes, greaterThan(before));
    },
  );
}
