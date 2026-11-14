// What "all messages" and "mentions only" write to the account's push
// rules. `.m.rule.encrypted` is the load-bearing one: it is what carries an
// encrypted message to the phone at all, where the extension decrypts it
// and applies the real rules. Disabling it hands the decision to a server
// that cannot see inside the message, so these tests fail if any edit ever
// touches it again.
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/channel_default.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/ui/shell/profile.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _message =
    '/client/v3/pushrules/global/underride/.m.rule.message/enabled';
const _encrypted =
    '/client/v3/pushrules/global/underride/.m.rule.encrypted/enabled';

Future<(Client, FakeMatrixApi)> _client() async {
  final api = FakeMatrixApi();
  final client = await openClient(
    httpClient: api,
    databasePath: inMemoryDatabasePath,
  );
  FakeMatrixApi.client = client;
  // The fake knows neither rule; teaching it both is what lets the test
  // prove only one of them is written.
  api.api['PUT']![_message] = (Object? _) => <String, Object?>{};
  api.api['PUT']![_encrypted] = (Object? _) => <String, Object?>{};
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse('https://fakeServer.notExisting'),
    newUserID: '@test:fakeServer.notExisting',
    newDeviceID: 'GHTYAJCE',
    newDeviceName: 'loaf on test',
    waitForFirstSync: true,
  );
  addTearDown(client.dispose);
  return (client, api);
}

List<String> _ruleWrites() => [
  for (final entry in FakeMatrixApi.calledEndpoints.entries)
    if (entry.key.contains('/pushrules/') && entry.value.isNotEmpty) entry.key,
]..sort();

PushRuleSet _rules({required bool message}) => PushRuleSet.fromJson({
  'underride': [
    {
      'rule_id': '.m.rule.message',
      'default': true,
      'enabled': message,
      'conditions': <Object?>[],
      'actions': ['notify'],
    },
    {
      'rule_id': '.m.rule.encrypted',
      'default': true,
      'enabled': true,
      'conditions': <Object?>[],
      'actions': ['notify'],
    },
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('mentions only disables the message rule and nothing else', () async {
    final (client, _) = await _client();
    await writeDefault(client, ChannelDefault.mentions);
    expect(_ruleWrites(), [_message]);
  });

  test('all messages enables the message rule and nothing else', () async {
    final (client, _) = await _client();
    await writeDefault(client, ChannelDefault.all);
    expect(_ruleWrites(), [_message]);
  });

  test('the repair enables an encrypted rule someone turned off', () async {
    final (client, _) = await _client();
    await client.handleSync(
      SyncUpdate.fromJson({
        'next_batch': 'b1',
        'account_data': {
          'events': [
            {
              'type': 'm.push_rules',
              'content': {
                'global': {
                  'underride': [
                    {
                      'rule_id': '.m.rule.encrypted',
                      'default': true,
                      'enabled': false,
                      'conditions': <Object?>[],
                      'actions': ['notify'],
                    },
                  ],
                },
              },
            },
          ],
        },
      }),
    );
    await repairEncryptedRule(client);
    expect(_ruleWrites(), [_encrypted]);
  });

  test('the repair writes nothing when the rule is already on', () async {
    final (client, _) = await _client();
    await repairEncryptedRule(client);
    expect(_ruleWrites(), isEmpty);
  });

  test('the message rule is what the setting reads back', () {
    expect(readDefault(_rules(message: true)), ChannelDefault.all);
    expect(readDefault(_rules(message: false)), ChannelDefault.mentions);
  });

  test('an account with no message rule notifies for everything', () {
    expect(readDefault(PushRuleSet.fromJson({})), ChannelDefault.all);
  });
}
