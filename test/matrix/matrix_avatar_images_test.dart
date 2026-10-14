import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/painting.dart';
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
  final paths = <String>[];
  var status = 200;
  var contentType = 'image/png';

  @override
  Future<http.Response> mockIntercept(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'GET' &&
        (path.contains('/thumbnail/') || path.contains('/download/'))) {
      paths.add(path);
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

/// A 1x1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Decodes [_png] whatever it is given, noting the size asked of a 4000 by
/// 3000 picture.
ImageDecoderCallback _recording(List<TargetImageSize?> asked) =>
    (buffer, {getTargetSize}) async {
      asked.add(getTargetSize?.call(4000, 3000));
      return instantiateImageCodec(_png);
    };

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
    await MxcImage(client, mxc, size: 64).bytes();
    expect(api.requests.single['authorization'], 'Bearer abcd');
  });

  test('a second fetch comes from the file store', () async {
    final api = _Api();
    final client = await _client(api);
    final thumbnail = MxcImage(client, mxc, size: 64);
    await thumbnail.bytes();
    await thumbnail.bytes();
    expect(api.requests, hasLength(1));
  });

  test('a thumbnail that fails leaves nothing cached', () async {
    final api = _Api();
    final client = await _client(api);
    final thumbnail = MxcImage(client, mxc, size: 64);
    api.status = 404;
    await expectLater(thumbnail.bytes(), throwsA(anything));
    api
      ..status = 200
      ..contentType = 'text/html';
    await expectLater(thumbnail.bytes(), throwsA(anything));
    final uri = await mxc.getThumbnailUri(client, width: 64, height: 64);
    expect(await client.database.getFile(uri), isNull);
  });

  test('an original is fetched whole, with the access token', () async {
    final api = _Api();
    final client = await _client(api);
    await MxcImage(client, mxc).bytes();
    expect(api.paths.single, contains('/download/'));
    expect(api.paths.single, isNot(contains('/thumbnail/')));
    expect(api.requests.single['authorization'], 'Bearer abcd');
  });

  test('a second original comes from the file store', () async {
    final api = _Api();
    final client = await _client(api);
    final original = MxcImage(client, mxc);
    await original.bytes();
    await original.bytes();
    expect(api.requests, hasLength(1));
  });

  test('an original and a thumbnail are cached apart', () async {
    final api = _Api();
    final client = await _client(api);
    await MxcImage(client, mxc).bytes();
    await MxcImage(client, mxc, size: 64).bytes();
    expect(api.requests, hasLength(2));
  });

  test('an original that fails leaves nothing cached', () async {
    final api = _Api()..status = 500;
    final client = await _client(api);
    await expectLater(MxcImage(client, mxc).bytes(), throwsA(anything));
    expect(
      await client.database.getFile(await mxc.getDownloadUri(client)),
      isNull,
    );
  });

  test('an original decodes no wider than 512', () async {
    final client = await _client(_Api());
    final asked = <TargetImageSize?>[];
    final image = MxcImage(client, mxc);
    final completer = image.loadImage(image, _recording(asked));
    final done = Completer<void>();
    completer.addListener(ImageStreamListener((_, _) => done.complete()));
    await done.future;
    expect(asked.single?.width, 512);
    expect(asked.single?.height, isNull);
  });

  test('a thumbnail decodes as the server sized it', () async {
    final client = await _client(_Api());
    final asked = <TargetImageSize?>[];
    final image = MxcImage(client, mxc, size: 64);
    final completer = image.loadImage(image, _recording(asked));
    final done = Completer<void>();
    completer.addListener(ImageStreamListener((_, _) => done.complete()));
    await done.future;
    expect(asked.single, isNull);
  });

  test('an mxc ref has an original; another scheme has none', () async {
    final client = await _client(_Api());
    final images = MatrixAvatarImages(client);
    expect(
      images.original(const AvatarRef('mxc://fake/abc')),
      MxcImage(client, mxc),
    );
    expect(images.original(const AvatarRef('https://x/y')), isNull);
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
    expect(provider, MxcImage(client, mxc, size: 128));
  });
}
