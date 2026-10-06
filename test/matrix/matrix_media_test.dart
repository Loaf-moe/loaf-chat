import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_avatar_images.dart';
import 'package:loaf_native/matrix/matrix_media.dart';
import 'package:loaf_native/matrix/media_images.dart';
import 'package:loaf_native/matrix/media_store.dart';
import 'package:loaf_native/ui/model/media_source.dart' show inlinePreviewCap;
import 'package:loaf_native/ui/model/models.dart' as ui;
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

late Client _client;
late Room _room;

Event _event(
  Map<String, Object?> content, {
  String type = 'm.room.message',
  Map<String, Object?>? unsigned,
}) => Event.fromJson({
  'type': type,
  'sender': '@ada:example.com',
  'event_id': r'$e1',
  'origin_server_ts': 1700000000000,
  'content': content,
  'unsigned': ?unsigned,
}, _room);

Map<String, Object?> _encrypted({Object? key}) => {
  'url': null,
  'key': key ?? {'k': 'a' * 43, 'alg': 'A256CTR', 'ext': true},
  'iv': 'b' * 22,
  'url2': null,
}..remove('url2');

void main() {
  late Directory root;
  late MatrixMediaSource source;

  setUp(() async {
    _client = await openClient(databasePath: inMemoryDatabasePath);
    addTearDown(_client.dispose);
    _room = Room(id: '!r:example.com', client: _client);
    root = Directory.systemTemp.createTempSync('matrix_media_test');
    addTearDown(() => root.deleteSync(recursive: true));
    final store = MediaStore(
      root: root,
      client: MockClient((_) async => throw StateError('no network')),
      downloadUri: (mxc) async => Uri.https('example.com', '/dl${mxc.path}'),
      accessToken: () => 'tok',
    );
    source = MatrixMediaSource(_client, store);
    addTearDown(source.dispose);
  });

  group('mediaOf', () {
    test('each msgtype maps to its kind', () {
      ui.MediaKind? kind(String type) =>
          mediaOf(_event({'msgtype': type, 'body': 'x'}))?.kind;
      expect(kind('m.image'), ui.MediaKind.image);
      expect(kind('m.video'), ui.MediaKind.video);
      expect(kind('m.audio'), ui.MediaKind.audio);
      expect(kind('m.file'), ui.MediaKind.file);
      expect(kind('m.text'), isNull);
      final sticker = mediaOf(_event({'body': 'hi'}, type: 'm.sticker'));
      expect(sticker?.kind, ui.MediaKind.image);
    });

    test('the same event mapped twice has an equal ref', () {
      // A row keeps showing an open's progress across timeline rebuilds,
      // which map every event afresh.
      Map<String, Object?> content(String url) => {
        'msgtype': 'm.file',
        'body': 'recipe.pdf',
        'url': url,
      };
      final once = mediaOf(_event(content('mxc://example.com/a')))!.ref;
      final again = mediaOf(_event(content('mxc://example.com/a')))!.ref;
      final other = mediaOf(_event(content('mxc://example.com/b')))!.ref;
      expect(again, once);
      expect(again.hashCode, once.hashCode);
      expect(other, isNot(once));
    });

    test('info fills size, type, dimensions and duration', () {
      final media = mediaOf(
        _event({
          'msgtype': 'm.video',
          'body': 'clip.mp4',
          'url': 'mxc://example.com/v',
          'info': {
            'w': 640,
            'h': 360,
            'size': 1234,
            'mimetype': 'video/mp4',
            'duration': 83000,
          },
        }),
      )!;
      expect(media.name, 'clip.mp4');
      expect(media.size, 1234);
      expect(media.mimeType, 'video/mp4');
      expect(media.dimensions, const Size(640, 360));
      expect(media.duration, const Duration(seconds: 83));
    });

    test('a media event missing its info maps to a file card', () {
      final media = mediaOf(_event({'msgtype': 'm.image', 'body': 'pic.png'}))!;
      expect(media.kind, ui.MediaKind.image);
      expect(media.name, 'pic.png');
      expect(media.size, isNull);
      expect(media.mimeType, isNull);
      expect(media.dimensions, isNull);
      expect(media.duration, isNull);
    });

    test('a content block of the wrong shapes still maps', () {
      final media = mediaOf(
        _event({
          'msgtype': 'm.file',
          'body': 7,
          'info': {'size': 'big', 'w': 'x', 'duration': null},
          'file': 'nonsense',
        }),
      )!;
      expect(media.kind, ui.MediaKind.file);
      expect(media.name, 'file');
      expect(media.size, isNull);
    });

    test('a caption is the body when the filename differs', () {
      expect(captionOf({'filename': 'a.jpg', 'body': 'look'}), 'look');
      expect(captionOf({'body': 'a.jpg'}), isNull);
      expect(captionOf({'filename': 'a.jpg', 'body': 'a.jpg'}), isNull);
      final media = mediaOf(
        _event({'msgtype': 'm.image', 'filename': 'a.jpg', 'body': 'look'}),
      )!;
      expect(media.name, 'a.jpg');
    });

    test('a thumbnail, or a small plain image, has a preview', () {
      bool has(Map<String, Object?> c) => mediaOf(_event(c))!.hasPreview;
      expect(
        has({
          'msgtype': 'm.video',
          'body': 'v',
          'info': {'thumbnail_url': 'mxc://example.com/t'},
        }),
        isTrue,
      );
      expect(has({'msgtype': 'm.video', 'body': 'v'}), isFalse);
      expect(
        has({'msgtype': 'm.image', 'body': 'i', 'url': 'mxc://example.com/i'}),
        isTrue,
      );
    });
  });

  group('previews', () {
    test('a plain image with no thumbnail is a server thumbnail', () {
      final media = mediaOf(
        _event({
          'msgtype': 'm.image',
          'body': 'pic.png',
          'url': 'mxc://example.com/pic',
          'info': {'size': 5000000},
        }),
      )!;
      final preview = source.preview(media, 500);
      expect(
        preview,
        isA<MxcThumbnail>()
            .having((t) => t.mxc, 'mxc', Uri.parse('mxc://example.com/pic'))
            .having((t) => t.size, 'size', 640),
      );
    });

    test(
      'an encrypted image with no thumbnail and over 2 MB has no preview',
      () {
        final media = mediaOf(
          _event({
            'msgtype': 'm.image',
            'body': 'big.png',
            'file': {..._encrypted(), 'url': 'mxc://example.com/big'},
            'info': {'size': 2000001},
          }),
        )!;
        expect(media.hasPreview, isFalse);
        expect(source.preview(media, 500), isNull);
      },
    );

    group('on another site', () {
      Map<String, Object?> bridged() => {
        'msgtype': 'm.image',
        'body': 'cat.png',
        'url': 'https://cdn.example.net/cat.png',
        'info': {'size': 2000, 'mimetype': 'image/png'},
      };

      test('a small image previews through the store, by default', () {
        final media = mediaOf(_event(bridged()))!;
        expect(media.hasPreview, isTrue);
        expect(source.preview(media, 500), isA<StoredFileImage>());
        expect(source.open(media).error, isNull);
      });

      test('it is a plain card with the setting off', () {
        final media = mediaOf(_event(bridged()), external: false)!;
        expect(media.hasPreview, isFalse);
        expect(source.preview(media, 500), isNull);
        expect(source.open(media).error, isNotNull);
      });

      test('an http link is never fetched', () {
        final media = mediaOf(
          _event({...bridged(), 'url': 'http://cdn.example.net/cat.png'}),
        )!;
        expect(media.hasPreview, isFalse);
      });

      test('a link beside an encrypted key is not followed', () {
        final media = mediaOf(
          _event({
            ...bridged(),
            'file': {..._encrypted(), 'url': 'https://cdn.example.net/x'},
          }),
        )!;
        expect(media.hasPreview, isFalse);
      });

      test('the access token stays with the homeserver', () async {
        final seen = <http.BaseRequest>[];
        final store = MediaStore(
          root: Directory('${root.path}/ext')..createSync(),
          client: MockClient.streaming((request, _) async {
            seen.add(request);
            return http.StreamedResponse(
              Stream.value([1, 2, 3]),
              200,
              contentLength: 3,
            );
          }),
          downloadUri: (mxc) async =>
              Uri.https('example.com', '/dl${mxc.path}'),
          accessToken: () => 'tok',
        );
        await MatrixMediaSource(
          _client,
          store,
        ).open(mediaOf(_event(bridged()))!).path;
        await MatrixMediaSource(_client, store)
            .open(
              mediaOf(_event({...bridged(), 'url': 'mxc://example.com/home'}))!,
            )
            .path;
        expect(seen.first.url.host, 'cdn.example.net');
        expect(seen.first.headers.containsKey('authorization'), isFalse);
        expect(seen.last.url.host, 'example.com');
        expect(seen.last.headers['authorization'], 'Bearer tok');
      });
    });

    test('a small encrypted image previews through the store', () {
      final media = mediaOf(
        _event({
          'msgtype': 'm.image',
          'body': 'small.png',
          'file': {..._encrypted(), 'url': 'mxc://example.com/small'},
          'info': {'size': 2000},
        }),
      )!;
      expect(media.hasPreview, isTrue);
      expect(source.preview(media, 500), isA<StoredFileImage>());
    });

    test('a thumbnail map previews through the store', () {
      final media = mediaOf(
        _event({
          'msgtype': 'm.video',
          'body': 'v.mp4',
          'url': 'mxc://example.com/v',
          'info': {
            'thumbnail_file': {..._encrypted(), 'url': 'mxc://example.com/t'},
          },
        }),
      )!;
      final preview = source.preview(media, 300) as StoredFileImage;
      expect(preview.bucket, 320);
    });

    test('a sending file previews from the SDK\'s cache', () {
      final media = mediaOf(
        _event(
          {
            'msgtype': 'm.image',
            'body': 'new.png',
            'filename': 'new.png',
            'info': {'size': 10},
          },
          unsigned: {'transaction_id': 'tx1'},
        ),
      )!;
      expect(
        source.preview(media, 300),
        isA<FileStoreImage>()
            .having((i) => i.uri, 'uri', Uri.parse('cache://thumbnail/tx1'))
            .having(
              (i) => i.fallback,
              'fallback',
              Uri.parse('cache://file/tx1'),
            ),
      );
      final video = mediaOf(
        _event(
          {'msgtype': 'm.video', 'body': 'v.mp4', 'filename': 'v.mp4'},
          unsigned: {'transaction_id': 'tx2'},
        ),
      )!;
      // Nothing of a video is cached until it has a thumbnail: no preview,
      // and the row says so up front rather than failing to draw one.
      expect(video.hasPreview, isFalse);
      expect(source.preview(video, 300), isNull);
      final thumbed = mediaOf(
        _event(
          {
            'msgtype': 'm.video',
            'body': 'v.mp4',
            'info': {'thumbnail_url': 'mxc://example.com/t'},
          },
          unsigned: {'transaction_id': 'tx4'},
        ),
      )!;
      expect((source.preview(thumbed, 300) as FileStoreImage).fallback, isNull);
    });

    test('a sent file with its echo\'s txid still reads from the server', () {
      final media = mediaOf(
        _event(
          {
            'msgtype': 'm.image',
            'body': 'sent.png',
            'url': 'mxc://example.com/sent',
          },
          unsigned: {'transaction_id': 'tx3'},
        ),
      )!;
      expect(source.preview(media, 300), isA<MxcThumbnail>());
    });
  });

  group('GIFs', () {
    ui.Media gif({bool encrypted = false, int? size = 1000}) => mediaOf(
      _event({
        'msgtype': 'm.image',
        'body': 'a.gif',
        if (encrypted)
          'file': {..._encrypted(), 'url': 'mxc://example.com/g'}
        else
          'url': 'mxc://example.com/g',
        'info': {'mimetype': 'image/gif', 'size': ?size},
      }),
    )!;

    test('a small plain GIF is drawn whole, to animate', () {
      final media = gif();
      expect(media.hasPreview, isTrue);
      expect(source.preview(media, 300), isA<StoredFileImage>());
    });

    test('a small encrypted GIF is drawn whole too', () {
      final media = gif(encrypted: true);
      expect(media.hasPreview, isTrue);
      expect(source.preview(media, 300), isA<StoredFileImage>());
    });

    test('a GIF over the cap, or of unknown size, keeps a still', () {
      expect(
        source.preview(gif(size: inlinePreviewCap + 1), 300),
        isA<MxcThumbnail>(),
      );
      expect(source.preview(gif(size: null), 300), isA<MxcThumbnail>());
      expect(
        gif(encrypted: true, size: inlinePreviewCap + 1).hasPreview,
        isFalse,
      );
    });

    test('retrying a small GIF retries its own file', () async {
      final media = gif();
      final file = source.open(media);
      await expectLater(file.path, throwsA(anything));
      source.retryPreview(media);
      expect(file.error, isNull);
    });
  });

  test('an image with nowhere to fetch from has no preview to offer', () {
    final media = mediaOf(_event({'msgtype': 'm.image', 'body': 'a.png'}))!;
    expect(media.hasPreview, isFalse);
    expect(source.preview(media, 300), isNull);
  });

  group('files', () {
    test('a broken file map fails the download, not the mapping', () async {
      // A server that would answer 200: only the empty key can fail this.
      final answering = MatrixMediaSource(
        _client,
        MediaStore(
          root: root,
          client: MockClient((_) async => http.Response('bytes', 200)),
          downloadUri: (mxc) async => Uri.https('example.com', '/dl'),
          accessToken: () => 'tok',
        ),
      );
      addTearDown(answering.dispose);
      final media = mediaOf(
        _event({
          'msgtype': 'm.file',
          'body': 'x.bin',
          'file': {'url': 'mxc://example.com/x'},
        }),
      )!;
      final file = answering.open(media);
      await expectLater(file.path, throwsA(isA<ArgumentError>()));
      expect(file.error, isA<ArgumentError>());
    });

    test('a file with nowhere to fetch from has already failed', () async {
      final media = mediaOf(_event({'msgtype': 'm.file', 'body': 'x.bin'}))!;
      final file = source.open(media);
      expect(file.error, isNotNull);
      await expectLater(file.path, throwsA(anything));
      file.retry(); // Nothing to start again, and no throw.
    });

    test('with no media folder, a file has already failed', () async {
      final bare = MatrixMediaSource(_client, null);
      final media = mediaOf(
        _event({
          'msgtype': 'm.file',
          'body': 'x.bin',
          'url': 'mxc://example.com/x',
        }),
      )!;
      final file = bare.open(media);
      expect(file.error, isA<StateError>());
      expect('${file.error}', contains('no media folder'));
    });

    test('two opens of one file are one download', () {
      final media = mediaOf(
        _event({
          'msgtype': 'm.file',
          'body': 'x.bin',
          'url': 'mxc://example.com/x',
        }),
      )!;
      expect(source.open(media), same(source.open(media)));
    });
  });

  test('buckets round up, and stop at the last', () {
    expect(bucketFor(500, buckets: timelineBuckets), 640);
    expect(bucketFor(5000, buckets: timelineBuckets), 1280);
    expect(bucketFor(100), 128);
  });
}
