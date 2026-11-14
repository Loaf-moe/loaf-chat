// Registering this device with the push gateway, and taking it off again.
// A pusher is what makes the homeserver send anything at all, so the body
// is pinned: a wrong app_id or format means pushes that never arrive, or
// arrive carrying message text the gateway should never see.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/push/ios_push.dart';
import 'package:loaf_native/push/pusher.dart';
// The SDK exports a Pusher of its own; this file means ours.
import 'package:matrix/matrix.dart' hide Pusher;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Never a real one, so a test can never register a device for push.
const _gateway = 'https://push.example/_matrix/push/v1/notify';
// The fake keys its record by what follows /_matrix.
const _endpoint = '/client/v3/pushers/set';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.loaf.chat/notify');
  Object? Function(MethodCall)? answer;

  setUp(() {
    answer = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => answer?.call(call));
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  Future<Client> client() async {
    final api = FakeMatrixApi();
    final client = await openClient(
      httpClient: api,
      databasePath: inMemoryDatabasePath,
    );
    FakeMatrixApi.client = client;
    await client.init(
      newToken: 'abcd',
      newHomeserver: Uri.parse('https://fakeServer.notExisting'),
      newUserID: '@test:fakeServer.notExisting',
      newDeviceID: 'GHTYAJCE',
      newDeviceName: 'loaf on test',
      waitForFirstSync: true,
    );
    addTearDown(client.dispose);
    return client;
  }

  List<Map<String, Object?>> posted() => [
    for (final body in FakeMatrixApi.calledEndpoints[_endpoint] ?? const [])
      jsonDecode(body as String) as Map<String, Object?>,
  ];

  Pusher pusher(Client c, {required bool enabled, bool release = true}) =>
      Pusher(
        client: c,
        push: IosPush(),
        enabled: () => enabled,
        release: release,
        gateway: _gateway,
      );

  test('a release build registers this device with the gateway', () async {
    answer = (c) => c.method == 'pushToken' ? 'ab12' : null;
    final c = await client();
    await pusher(c, enabled: true).sync();
    final body = posted().last;
    expect(body['app_id'], 'moe.loaf.chat.ios');
    expect(body['pushkey'], 'ab12');
    expect(body['kind'], 'http');
    expect(body['app_display_name'], 'Loaf Chat');
    expect(body['lang'], 'en');
    // event_id_only: the gateway is told which message, never what it says.
    expect(body['data'], {'url': _gateway, 'format': 'event_id_only'});
    // Not appended: this device has one pusher, replaced each time.
    expect(body['append'], false);
  });

  test('a debug build registers nothing', () async {
    answer = (c) => c.method == 'pushToken' ? 'ab12' : null;
    final c = await client();
    await pusher(c, enabled: true, release: false).sync();
    expect(posted(), isEmpty);
  });

  test('turning notifications off takes the pusher away', () async {
    answer = (c) => c.method == 'pushToken' ? 'ab12' : null;
    final c = await client();
    await pusher(c, enabled: true).sync();
    await pusher(c, enabled: false).sync();
    final body = posted().last;
    expect(body['app_id'], 'moe.loaf.chat.ios');
    expect(body['pushkey'], 'ab12');
    // A null kind is how Matrix deletes a pusher.
    expect(body.containsKey('kind'), isTrue);
    expect(body['kind'], isNull);
  });

  test('no token registers nothing', () async {
    answer = (_) => null;
    final c = await client();
    await pusher(c, enabled: true).sync();
    expect(posted(), isEmpty);
  });
}
