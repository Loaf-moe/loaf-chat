import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_avatar_images.dart';
import 'package:loaf_native/matrix/matrix_link_previews.dart';
import 'package:loaf_native/ui/model/link_previews.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _modern = 'https://fakeServer.notExisting';
const _legacy = 'https://fakeserverpriortoauthmedia.notexisting';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

http.Response _refusal(String errcode, int status) =>
    _json({'errcode': errcode, 'error': 'no'}, status);

/// The fake server, plus previews and the capabilities that govern them.
/// Each answers with whatever the test last set, and can be held back.
class _Api extends FakeMatrixApi {
  /// The paths previews were asked on, in order.
  final previews = <String>[];
  var capabilityAsks = 0;

  FutureOr<http.Response> Function(Uri link) preview = (_) => _json({
    'og:title': 'Bake day',
    'og:description': 'Flour, water, salt and time.',
    'og:image': 'mxc://loaf.moe/oven',
    'matrix:image:size': 1024,
  });

  FutureOr<http.Response> Function() capabilities = () =>
      _json({'capabilities': <String, Object?>{}});

  @override
  Future<http.Response> mockIntercept(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/preview_url')) {
      previews.add(path);
      return preview(Uri.parse(request.url.queryParameters['url']!));
    }
    if (path.endsWith('/capabilities')) {
      capabilityAsks++;
      return capabilities();
    }
    return super.mockIntercept(request);
  }
}

Future<Client> _client(_Api api, {String homeserver = _modern}) async {
  final client = await openClient(
    httpClient: api,
    databasePath: inMemoryDatabasePath,
  );
  FakeMatrixApi.client = client;
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse(homeserver),
    newUserID: '@test:fakeServer.notExisting',
    newDeviceID: 'GHTYAJCE',
    newDeviceName: 'loaf on test',
    waitForFirstSync: false,
  );
  addTearDown(client.dispose);
  return client;
}

/// Waits for [state] to stop loading, and gives what it became.
Future<LinkPreviewState> _answered(
  ValueListenable<LinkPreviewState> state,
) async {
  final give = DateTime.now().add(const Duration(seconds: 10));
  while (state.value is LinkPreviewLoading && DateTime.now().isBefore(give)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return state.value;
}

/// Time for a request that should not be made to show itself.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  final link = Uri.parse('https://loaf.moe/bake');
  final other = Uri.parse('https://loaf.moe/proof');

  late _Api api;
  late Client client;
  late MatrixLinkPreviews previews;
  var clock = DateTime.utc(2026, 10, 12, 12);

  Future<void> open({String homeserver = _modern}) async {
    api = _Api();
    client = await _client(api, homeserver: homeserver);
    clock = DateTime.utc(2026, 10, 12, 12);
    previews = MatrixLinkPreviews(client, now: () => clock);
    addTearDown(previews.dispose);
  }

  Future<LinkPreview> ready(Uri link) async =>
      (await _answered(previews.of(link)) as LinkPreviewReady).preview;

  group('reading the reply', () {
    test(
      'a page\'s title, description and picture become its preview',
      () async {
        await open();
        final preview = await ready(link);
        expect(preview.title, 'Bake day');
        expect(preview.description, 'Flour, water, salt and time.');
        expect(
          preview.image,
          MxcThumbnail(client, Uri.parse('mxc://loaf.moe/oven'), 320),
        );
      },
    );

    test('the link asked about is the one in the message', () async {
      await open();
      Uri? asked;
      api.preview = (link) {
        asked = link;
        return _json({'og:title': 'Bake day'});
      };
      await ready(link);
      expect(asked, link);
    });

    test('a title or description that is not text is left out', () async {
      await open();
      api.preview = (_) => _json({
        'og:title': 42,
        'og:description': ['a', 'b'],
        'og:image': 'mxc://loaf.moe/oven',
      });
      final preview = await ready(link);
      expect(preview.title, isNull);
      expect(preview.description, isNull);
      expect(preview.image, isNotNull);
    });

    test('a picture that is not on the homeserver is left out', () async {
      await open();
      api.preview = (_) => _json({
        'og:title': 'Bake day',
        'og:image': 'https://elsewhere.example/oven.jpg',
      });
      final preview = await ready(link);
      expect(preview.title, 'Bake day');
      expect(preview.image, isNull);
    });

    test('a reply with nothing to draw is no preview', () async {
      await open();
      api.preview = (_) => _json(<String, Object?>{});
      expect(await _answered(previews.of(link)), isA<LinkPreviewNone>());
    });

    for (final (what, body) in [
      ('a size that is not a number', {'matrix:image:size': 'big'}),
      ('a picture that is not text', {'og:image': 7}),
    ]) {
      test(
        'a reply with $what is no preview, and is not asked for again',
        () async {
          await open();
          api.preview = (_) => _json({'og:title': 'Bake day', ...body});
          expect(await _answered(previews.of(link)), isA<LinkPreviewNone>());
          clock = clock.add(const Duration(hours: 1));
          expect(previews.of(link).value, isA<LinkPreviewNone>());
          await _settle();
          expect(api.previews, hasLength(1));
        },
      );
    }

    test('a server without authenticated media is asked the old way', () async {
      await open(homeserver: _legacy);
      await ready(link);
      expect(api.previews.single, endsWith('/media/v3/preview_url'));
    });

    test('a server with authenticated media is asked the new way', () async {
      await open();
      await ready(link);
      expect(api.previews.single, endsWith('/client/v1/media/preview_url'));
    });
  });

  group('asking', () {
    test('rows asking about one link share one request', () async {
      await open();
      final first = previews.of(link);
      final second = previews.of(link);
      expect(second, same(first));
      await _answered(first);
      previews.of(link);
      await _settle();
      expect(api.previews, hasLength(1));
    });

    test('a link the server refuses is not asked for again', () async {
      await open();
      api.preview = (_) => _refusal('M_FORBIDDEN', 403);
      expect(await _answered(previews.of(link)), isA<LinkPreviewNone>());
      clock = clock.add(const Duration(hours: 1));
      expect(previews.of(link).value, isA<LinkPreviewNone>());
      await _settle();
      expect(api.previews, hasLength(1));
    });

    for (final (what, FutureOr<http.Response> Function(Uri) answer) in [
      ('a request that times out', (_) => throw TimeoutException('no answer')),
      (
        'a request that cannot be sent',
        (_) => throw http.ClientException('offline'),
      ),
      ('a rate limit', (_) => _refusal('M_LIMIT_EXCEEDED', 429)),
      ('an error that is not Matrix\'s', (_) => http.Response('<html>', 502)),
      ('a page in place of an answer', (_) => http.Response('<html>', 200)),
      (
        'a picture that is no address',
        (_) => _json({'og:title': 'Bake day', 'og:image': 'http://['}),
      ),
    ]) {
      test('$what is no preview, asked for again after a minute', () async {
        await open();
        api.preview = answer;
        final state = previews.of(link);
        expect(await _answered(state), isA<LinkPreviewNone>());

        clock = clock.add(const Duration(seconds: 59));
        previews.of(link);
        await _settle();
        expect(api.previews, hasLength(1), reason: 'within the minute');

        api.preview = (_) => _json({'og:title': 'Bake day'});
        clock = clock.add(const Duration(seconds: 1));
        expect(previews.of(link), same(state));
        await _until(() => state.value is LinkPreviewReady);
        expect(state.value, isA<LinkPreviewReady>());
        expect(api.previews, hasLength(2));
      });
    }

    test('rows asking again after the minute share one request', () async {
      await open();
      api.preview = (_) => throw TimeoutException('no answer');
      final state = previews.of(link);
      await _answered(state);

      final held = Completer<http.Response>();
      api.preview = (_) => held.future;
      clock = clock.add(const Duration(minutes: 1));
      previews.of(link);
      previews.of(link);
      await _until(() => state.value is LinkPreviewLoading);
      await _settle();
      expect(api.previews, hasLength(2));
      held.complete(_json({'og:title': 'Bake day'}));
      expect(await _answered(state), isA<LinkPreviewReady>());
    });
  });

  group('a server that says whether it previews', () {
    Map<String, Object?> capability(Object? value) => {
      'capabilities': {'io.element.msc4452.preview_url': value},
    };

    test('saying it does not is asked for none', () async {
      await open();
      api.capabilities = () => _json(capability({'enabled': false}));
      expect(await _answered(previews.of(link)), isA<LinkPreviewNone>());
      expect(await _answered(previews.of(other)), isA<LinkPreviewNone>());
      await _settle();
      expect(api.previews, isEmpty);
    });

    test('a link asked about before it answers waits for the answer', () async {
      await open();
      final held = Completer<http.Response>();
      api.capabilities = () => held.future;
      final state = previews.of(link);
      await _settle();
      expect(state.value, isA<LinkPreviewLoading>());
      expect(api.previews, isEmpty);
      held.complete(_json(capability({'enabled': false})));
      expect(await _answered(state), isA<LinkPreviewNone>());
      expect(api.previews, isEmpty);
    });

    for (final (what, FutureOr<http.Response> Function() answer) in [
      ('saying it does', () => _json(capability({'enabled': true}))),
      ('saying nothing of it', () => _json({'capabilities': {}})),
      ('saying it in another shape', () => _json(capability(false))),
      ('refusing to say', () => _refusal('M_UNKNOWN', 500)),
      ('not answering', () => throw TimeoutException('no answer')),
      ('answering with something else', () => http.Response('<html>', 502)),
    ]) {
      test('$what is asked for previews', () async {
        await open();
        api.capabilities = answer;
        expect(await _answered(previews.of(link)), isA<LinkPreviewReady>());
      });
    }

    test('is asked once, however many links there are', () async {
      await open();
      final held = Completer<http.Response>();
      api.capabilities = () => held.future;
      final first = previews.of(link);
      final second = previews.of(other);
      await _until(() => api.capabilityAsks > 0);
      held.complete(_json({'capabilities': <String, Object?>{}}));
      await _answered(first);
      await _answered(second);
      await _answered(previews.of(Uri.parse('https://loaf.moe/crumb')));
      expect(api.capabilityAsks, 1);
    });
  });

  group('after sign-out', () {
    test('an answer still on its way changes nothing', () async {
      await open();
      final held = Completer<http.Response>();
      api.preview = (_) => held.future;
      final state = previews.of(link);
      await _until(() => api.previews.isNotEmpty);
      previews.dispose();
      held.complete(_json({'og:title': 'Bake day'}));
      await _settle();
      expect(state.value, isA<LinkPreviewLoading>());
    });

    test('a link has no preview, and nothing is asked', () async {
      await open();
      previews.dispose();
      expect(previews.of(link).value, isA<LinkPreviewNone>());
      await _settle();
      expect(api.previews, isEmpty);
      expect(api.capabilityAsks, 0);
    });
  });
}

Future<void> _until(bool Function() done) async {
  final give = DateTime.now().add(const Duration(seconds: 10));
  while (!done() && DateTime.now().isBefore(give)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
