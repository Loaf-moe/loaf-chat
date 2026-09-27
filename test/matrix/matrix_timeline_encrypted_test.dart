import 'dart:io';

import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/device_trust.dart';
import 'package:loaf_native/matrix/matrix_timeline.dart';
import 'package:loaf_native/ui/auth/loaf_session.dart' show DeviceTrust;
import 'package:loaf_native/ui/model/models.dart' as ui;
import 'package:matrix/encryption.dart';
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

/// Lets the SDK's streams deliver.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  late Client mine;

  setUp(() async {
    mine = await cryptoClient();
    await _sync(mine);
  });

  MatrixTimeline open() {
    final t = MatrixTimeline(
      mine.getRoomById(_room)!,
      you: const ui.Member(me, 'Me', Colors.grey),
      member: (id) => ui.Member(id, id, Colors.grey),
    );
    addTearDown(t.dispose);
    return t;
  }

  test(
    'an encrypted room is written in once this device is verified',
    () async {
      final t = open();
      await _settle();
      expect(t.writable, isFalse);
      await mine.restoreCryptoIdentity(fixtureRecoveryKey);
      expect(t.writable, isTrue);
    },
  );

  test('verified stays verified after a relaunch', () async {
    final dir = await Directory.systemTemp.createTemp('loaf-e2ee');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/loaf.sqlite';
    final before = await cryptoClient(path: path);
    await _sync(before);
    await before.restoreCryptoIdentity(fixtureRecoveryKey);
    expect(trustOf(before), DeviceTrust.verified);

    final after = await relaunch(before, path);
    expect(trustOf(after), DeviceTrust.verified);
    final t = MatrixTimeline(
      after.getRoomById(_room)!,
      you: const ui.Member(me, 'Me', Colors.grey),
      member: (id) => ui.Member(id, id, Colors.grey),
    );
    addTearDown(t.dispose);
    expect(t.writable, isTrue);
  });

  test('a locked message reads once its key arrives', () async {
    final theirs = await cryptoClient(
      api: FakeMatrixApi.currentApi,
      asOther: true,
    );
    await theirs.updateUserDeviceKeys(additionalUsers: {me});
    await _sync(theirs);
    final sealed = await theirs.encryption!.encryptGroupMessagePayload(_room, {
      'msgtype': 'm.text',
      'body': 'the cake is in the oven',
    });

    final t = open();
    await _settle();
    await _sync(mine, [
      {
        'type': EventTypes.Encrypted,
        'sender': other,
        'content': sealed,
        'event_id': '\$sealed',
        'origin_server_ts': 1700000001000,
      },
    ]);
    await _settle();
    expect(t.messages.single.locked, isTrue);

    var told = 0;
    t.addListener(() => told++);
    // As a forwarded key, or key backup, would bring it: exported from the
    // sender's own copy, from the first message on.
    final sessionId = sealed['session_id'] as String;
    final key = theirs.encryption!.keyManager
        .getInboundGroupSession(_room, sessionId)!
        .inboundGroupSession!
        .exportAtFirstKnownIndex();
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
    await _settle();
    expect(told, greaterThan(0));
    expect(t.messages.single.locked, isFalse);
    expect(t.messages.single.body, 'the cake is in the oven');
  });
}
