// rules.json is the one thing the iOS extension cannot fail open about by
// guessing: an empty ruleset silences everything, so a missing file must
// stay missing rather than become an empty one. These pin that, the shape
// the crate is handed, and that the document is rewritten only when it
// would say something different.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/push/rules_file.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';
var _batch = 0;

Future<(Client, FakeMatrixApi)> _client() async {
  final api = FakeMatrixApi();
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
    waitForFirstSync: true,
  );
  addTearDown(client.dispose);
  return (client, api);
}

Future<void> _syncRules(Client client, Map<String, Object?> ruleset) =>
    client.handleSync(
      SyncUpdate.fromJson({
        'next_batch': 'b${_batch++}',
        'account_data': {
          'events': [
            // m.push_rules nests the ruleset under `global`; content that
            // lacks it leaves the client with no rules at all.
            {
              'type': 'm.push_rules',
              'content': {'global': ruleset},
            },
          ],
        },
      }),
    );

File _tempFile(String name) {
  final dir = Directory.systemTemp.createTempSync('rules');
  addTearDown(() => dir.deleteSync(recursive: true));
  return File('${dir.path}/$name');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the document names you, the time, and the rules as the server sends '
      'them', () async {
    final (client, _) = await _client();
    final rules = client.globalPushRules!;
    final now = DateTime.utc(2026, 11, 14, 9);
    final doc = rulesFile(
      userId: _me,
      displayName: 'mochi',
      rules: rules,
      now: now,
    );
    expect(doc['user_id'], _me);
    expect(doc['display_name'], 'mochi');
    expect(doc['written_at'], now.millisecondsSinceEpoch);
    expect(doc['rules'], rules.toJson());
    // It is handed to the crate as text, so it must survive the trip.
    expect(jsonDecode(jsonEncode(doc)), doc);
  });

  test('a display name of none is recorded as none, not as empty', () async {
    final (client, _) = await _client();
    final doc = rulesFile(
      userId: _me,
      displayName: null,
      rules: client.globalPushRules!,
      now: DateTime.utc(2026),
    );
    expect(doc.containsKey('display_name'), isTrue);
    expect(doc['display_name'], isNull);
  });

  test('no rules yet writes nothing at all', () async {
    // A signed-out client: an empty ruleset would silence every push, and
    // the extension only fails open on a file that is not there.
    final client = await openClient(databasePath: inMemoryDatabasePath);
    addTearDown(client.dispose);
    final file = _tempFile('rules.json');
    final writer = RulesWriter(client, file);
    addTearDown(writer.dispose);
    await pumpEventQueue();
    expect(file.existsSync(), isFalse);
  });

  test('rewrites only when the rules would differ', () async {
    final (client, _) = await _client();
    final file = _tempFile('rules.json');
    final writer = RulesWriter(client, file);
    addTearDown(writer.dispose);
    await pumpEventQueue();

    expect(file.existsSync(), isTrue);
    expect(jsonDecode(file.readAsStringSync())['rules'], isNotNull);

    // The same rules arriving again say nothing new.
    file.writeAsStringSync('sentinel');
    await _syncRules(client, client.globalPushRules!.toJson());
    await pumpEventQueue();
    expect(file.readAsStringSync(), 'sentinel');

    // Flipping a rule the server already sent, so the ruleset is one the
    // SDK is certain to parse back.
    final before = jsonEncode(client.globalPushRules!.toJson());
    final changed = client.globalPushRules!.toJson();
    final override = changed['override']! as List;
    final first = override.first as Map<String, Object?>;
    first['enabled'] = !(first['enabled']! as bool);
    await _syncRules(client, changed);
    await pumpEventQueue();
    expect(
      jsonEncode(client.globalPushRules!.toJson()),
      isNot(before),
      reason: 'the sync has to change the rules, or this proves nothing',
    );
    expect(file.readAsStringSync(), isNot('sentinel'));
    expect(
      jsonDecode(file.readAsStringSync())['rules'],
      client.globalPushRules!.toJson(),
    );
  });

  test('a new display name rewrites it', () async {
    final (client, api) = await _client();
    final file = _tempFile('rules.json');
    final writer = RulesWriter(client, file);
    addTearDown(writer.dispose);
    await pumpEventQueue();

    file.writeAsStringSync('sentinel');
    api.api['GET']!['/client/v3/profile/${Uri.encodeComponent(_me)}'] = (
      Object? _,
    ) => {'displayname': 'Mochi the Second'};
    client.onUserProfileUpdate.add(_me);
    await pumpEventQueue();

    expect(
      jsonDecode(file.readAsStringSync())['display_name'],
      'Mochi the Second',
    );
  });

  test('nothing is left beside the document', () async {
    final (client, _) = await _client();
    final file = _tempFile('rules.json');
    final writer = RulesWriter(client, file);
    addTearDown(writer.dispose);
    await pumpEventQueue();

    expect(file.existsSync(), isTrue);
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });
}
