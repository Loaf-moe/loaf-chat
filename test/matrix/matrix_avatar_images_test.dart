import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_avatar_images.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The fake server, plus thumbnails: it records each request's headers and
/// answers with whatever [status] and [contentType] say.
class _Api extends FakeMatrixApi {
  final requests = <Map<String, String>>[];
  var status = 200;
  var contentType = 'image/png';

  @override
  Future<http.Response> mockIntercept(http.Request request) async {
    if (request.method == 'GET' && request.url.path.contains('/thumbnail/')) {
      requests.add(request.headers);
      return http.Response.bytes(
        utf8.encode('pixels'),
        status,
        headers: {'content-type': contentType},
      );
    }
    return super.mockIntercept(request);
  }
}

Future<Client> _client(_Api api) async {
  // The file store needs a directory; it is what makes a fetch stick.
  final dir = await Directory.systemTemp.createTemp('loaf_avatars');
  addTearDown(() => dir.delete(recursive: true));
  final client = await openClient(
    httpClient: api,
    databasePath: inMemoryDatabasePath,
    mediaPath: dir.path,
  );
  FakeMatrixApi.client = client;
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse('https://fakeServer.notExisting'),
    newUserID: '@test:fakeServer.notExisting',
    newDeviceID: 'GHTYAJCE',
    newDeviceName: 'loaf on test',
    waitForFirstSync: false,
  );
  addTearDown(client.dispose);
  return client;
}

void main() {
  final mxc = Uri.parse('mxc://fake/abc');

  test('buckets round up to 64, 128 and 320', () {
    expect(bucketFor(1), 64);
    expect(bucketFor(64), 64);
    expect(bucketFor(65), 128);
    expect(bucketFor(129), 320);
    expect(bucketFor(2000), 320);
  });

  test('a thumbnail is fetched with the access token', () async {
    final api = _Api();
    final client = await _client(api);
    await MxcThumbnail(client, mxc, 64).bytes();
    expect(api.requests.single['authorization'], 'Bearer abcd');
  });

  test('a second fetch comes from the file store', () async {
    final api = _Api();
    final client = await _client(api);
    final thumbnail = MxcThumbnail(client, mxc, 64);
    await thumbnail.bytes();
    await thumbnail.bytes();
    expect(api.requests, hasLength(1));
  });

  test('a thumbnail that fails leaves nothing cached', () async {
    final api = _Api();
    final client = await _client(api);
    final thumbnail = MxcThumbnail(client, mxc, 64);
    api.status = 404;
    await expectLater(thumbnail.bytes(), throwsA(anything));
    api
      ..status = 200
      ..contentType = 'text/html';
    await expectLater(thumbnail.bytes(), throwsA(anything));
    final uri = await mxc.getThumbnailUri(client, width: 64, height: 64);
    expect(await client.database.getFile(uri), isNull);
  });

  test('a non-mxc ref resolves to nothing', () async {
    final client = await _client(_Api());
    expect(
      MatrixAvatarImages(client).resolve(const AvatarRef('https://x/y'), 64),
      isNull,
    );
  });

  test('an mxc ref resolves to a thumbnail in its bucket', () async {
    final client = await _client(_Api());
    final provider = MatrixAvatarImages(client)
        .resolve(const AvatarRef('mxc://fake/abc'), 100);
    expect(provider, MxcThumbnail(client, mxc, 128));
  });
}
