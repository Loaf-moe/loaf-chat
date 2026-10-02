import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loaf_media/loaf_media.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_media.dart';
import 'package:loaf_native/matrix/media_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Its own file: the binding the mocked channel needs is kept out of the
// other media tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('moe.loaf.chat/media');

  test('signing out ends every video stream, failing its readers', () async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final client = await openClient(databasePath: inMemoryDatabasePath);
    addTearDown(client.dispose);
    final root = Directory.systemTemp.createTempSync('media_sign_out_test');
    addTearDown(() => root.deleteSync(recursive: true));
    // A download that never finishes: the video is mid-stream.
    final gate = StreamController<List<int>>();
    addTearDown(() => unawaited(gate.close()));
    final store = MediaStore(
      root: root,
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(gate.stream, 200),
      ),
      downloadUri: (mxc) async => Uri.https('example.com', '/dl${mxc.path}'),
      accessToken: () => 'tok',
    );
    final source = MatrixMediaSource(client, store);
    final file = store.open(
      MediaSpec(mxc: Uri.parse('mxc://example.com/v'), name: 'v.mp4'),
    );
    VideoStreams.attach(file);
    await Future<void>.delayed(Duration.zero);
    expect([for (final c in calls) c.method], ['stream.begin']);

    source.dispose();
    await Future<void>.delayed(Duration.zero);
    expect([for (final c in calls) c.method], ['stream.begin', 'stream.end']);
    expect((calls.last.arguments as Map)['id'], file.id);

    // The row going afterwards has nothing left to end.
    VideoStreams.detach(file);
    await Future<void>.delayed(Duration.zero);
    expect(calls, hasLength(2));
  });
}
