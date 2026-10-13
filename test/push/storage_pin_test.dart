// The iOS extension reads loaf.sqlite without the SDK. This pins what it
// reads, so an SDK upgrade that moves it fails here rather than on a phone.
//
// box_client values are stored as the raw strings (no JSON wrapping);
// box_inbound_group_session values are a JSON object per session id.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption/utils/pickle_key.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:vodozemac/vodozemac.dart' as vod;

import '../matrix/crypto_harness.dart';

const fixture = 'packages/loaf_push/rust/tests/fixtures/sdk.json';
const roomId = '!726s6s6q:example.com'; // an encrypted room in FakeMatrixApi

void main() {
  test('the store the extension reads', () async {
    final dir = await Directory.systemTemp.createTemp('pin');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/loaf.sqlite';
    final client = await cryptoClient(path: path);
    final room = client.getRoomById(roomId)!;
    final sent = await client.encryption!.encryptGroupMessagePayload(roomId, {
      'msgtype': 'm.text',
      'body': 'pinned',
    });
    // Closes the file so the read below sees what the SDK wrote; the
    // harness's own tear-down closing it again is harmless.
    await client.dispose(closeDatabase: true);

    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    addTearDown(db.close);
    String? box(String table, String key) =>
        db.select('SELECT v FROM $table WHERE k = ?', [key]).firstOrNull?['v']
            as String?;

    final clientRow = {
      for (final k in [
        'homeserver_url',
        'token',
        'token_expires_at',
        'user_id',
      ])
        k: box('box_client', k),
    };
    expect(clientRow['homeserver_url'], isNotNull);
    expect(clientRow['token'], isNotNull);
    expect(clientRow['user_id'], isNotNull);
    final sessionRow = box(
      'box_inbound_group_session',
      sent['session_id'] as String,
    );
    expect(sessionRow, isNotNull);
    final session = jsonDecode(sessionRow!) as Map<String, Object?>;
    expect(session.keys, containsAll(['room_id', 'session_id', 'pickle']));
    expect(session['room_id'], room.id);
    final userId = clientRow['user_id']!;
    expect(userId, client.userID);
    expect(clientRow['token'], 'abcd');
    expect(clientRow['homeserver_url'], startsWith('https://'));
    // The key derivation the Rust crate mirrors.
    vod.InboundGroupSession.fromPickleEncrypted(
      pickle: session['pickle']! as String,
      pickleKey: userId.toPickleKey(),
    );

    if (Platform.environment['LOAF_PUSH_FIXTURE'] == 'write') {
      await File(fixture).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'user_id': userId,
          'client': clientRow,
          'session_row': sessionRow,
          'room_id': room.id,
          'event_content': sent,
          'plaintext_body': 'pinned',
        }),
      );
    }
    final pinned = jsonDecode(await File(fixture).readAsString()) as Map;
    expect((pinned['client'] as Map).keys, clientRow.keys);
    expect(
      (jsonDecode(pinned['session_row'] as String) as Map).keys.toSet(),
      session.keys.toSet(),
    );
  });
}
