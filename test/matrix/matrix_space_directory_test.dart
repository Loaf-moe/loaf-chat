import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loaf_native/matrix/client_factory.dart';
import 'package:loaf_native/matrix/matrix_space_directory.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/rooms/rooms.dart' show SpaceNotFound;
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _me = '@test:fakeServer.notExisting';

/// The fake server, plus the endpoints a directory needs: public rooms,
/// alias resolution and `/hierarchy`, none of which the base fake answers.
class _Api extends FakeMatrixApi {
  /// The body `queryPublicRooms` sent, decoded, for the last call.
  Map<String, Object?>? publicRoomsRequest;
  Map<String, Object?>? publicRoomsResponse;

  String? aliasRoomId;
  List<String>? aliasServers;
  var aliasNotFound = false;

  /// Each space's `/hierarchy` pages, in order, keyed by space id. A
  /// missing key answers `M_NOT_FOUND`.
  final hierarchyPages = <String, List<Map<String, Object?>>>{};

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    final path = request.url.path;
    if (request.method == 'POST' && path.endsWith('/publicRooms')) {
      publicRoomsRequest = jsonDecode(request.body) as Map<String, Object?>;
      return http.Response(
        jsonEncode(publicRoomsResponse ?? {'chunk': <Object?>[]}),
        200,
      );
    }
    if (request.method == 'GET' && path.contains('/directory/room/')) {
      if (aliasNotFound) {
        return http.Response(
          jsonEncode({'errcode': 'M_NOT_FOUND', 'error': 'not found'}),
          404,
        );
      }
      return http.Response(
        jsonEncode({'room_id': aliasRoomId, 'servers': aliasServers ?? []}),
        200,
      );
    }
    if (request.method == 'GET' && path.contains('/hierarchy')) {
      final spaceId = Uri.decodeComponent(
        path.split('/rooms/')[1].split('/hierarchy')[0],
      );
      final pages = hierarchyPages[spaceId];
      if (pages == null) {
        return http.Response(
          jsonEncode({'errcode': 'M_NOT_FOUND', 'error': 'not found'}),
          404,
        );
      }
      final from = request.url.queryParameters['from'];
      final index = from == null ? 0 : int.parse(from);
      final page = index < pages.length ? pages[index] : {'rooms': <Object?>[]};
      return http.Response(jsonEncode(page), 200);
    }
    return super.mockIntercept(request);
  }
}

Future<Client> _client({_Api? api}) async {
  final client = await openClient(
    httpClient: api ?? _Api(),
    databasePath: inMemoryDatabasePath,
  );
  FakeMatrixApi.client = client;
  await client.init(
    newToken: 'abcd',
    newHomeserver: Uri.parse('https://fakeServer.notExisting'),
    newUserID: _me,
    newDeviceID: 'GHTYAJCE',
    newDeviceName: 'loaf on test',
  );
  addTearDown(client.dispose);
  return client;
}

/// Lets the SDK's streams deliver.
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

/// A `/publicRooms` chunk.
Map<String, Object?> chunk(
  String id, {
  String? name,
  String? canonicalAlias,
  String joinRule = 'public',
  int members = 1,
  String? topic,
}) => {
  'room_id': id,
  'guest_can_join': false,
  'world_readable': true,
  'num_joined_members': members,
  'name': ?name,
  'canonical_alias': ?canonicalAlias,
  'join_rule': joinRule,
  'topic': ?topic,
};

/// A `/hierarchy` chunk, for a space or one of its channels.
Map<String, Object?> hierarchyChunk(
  String id, {
  String? name,
  String? canonicalAlias,
  String? roomType,
  String joinRule = 'public',
  int members = 1,
  String? topic,
}) => {
  'room_id': id,
  'guest_can_join': false,
  'world_readable': true,
  'num_joined_members': members,
  'name': ?name,
  'canonical_alias': ?canonicalAlias,
  'room_type': ?roomType,
  'join_rule': joinRule,
  'topic': ?topic,
  'children_state': <Object?>[],
};

void main() {
  test('public spaces are filtered to spaces', () async {
    final api = _Api()
      ..publicRoomsResponse = {
        'chunk': [
          chunk(
            '!bakers:loaf.moe',
            name: 'Bakers',
            canonicalAlias: '#bakers:loaf.moe',
            members: 12,
            topic: 'sourdough talk',
          ),
        ],
      };
    final client = await _client(api: api);
    final directory = MatrixSpaceDirectory(client);

    final previews = await directory.publicSpaces('loaf.moe');
    await _settle();

    expect(api.publicRoomsRequest?['filter'], {
      'room_types': ['m.space'],
    });
    expect(previews, hasLength(1));
    final preview = previews.single;
    expect(preview.alias, '#bakers:loaf.moe');
    expect(preview.space.id, '!bakers:loaf.moe');
    expect(preview.space.name, 'Bakers');
    expect(preview.topic, 'sourdough talk');
    expect(preview.memberCount, 12);
    expect(preview.inviteOnly, isFalse);
  });

  test('an alias looks up and previews', () async {
    final api = _Api()
      ..aliasRoomId = '!bakers:loaf.moe'
      ..aliasServers = ['loaf.moe'];
    api.hierarchyPages['!bakers:loaf.moe'] = [
      {
        'rooms': [
          hierarchyChunk(
            '!bakers:loaf.moe',
            name: 'Bakers',
            topic: 'sourdough',
          ),
          hierarchyChunk('!general:loaf.moe', name: 'general'),
          hierarchyChunk(
            '!oven:loaf.moe',
            name: 'oven',
            roomType: 'org.matrix.msc3417.call',
          ),
        ],
      },
    ];
    final client = await _client(api: api);
    final directory = MatrixSpaceDirectory(client);

    final preview = await directory.lookUp('#bakers:loaf.moe');
    await _settle();

    expect(preview.space.id, '!bakers:loaf.moe');
    expect(preview.topic, 'sourdough');
    expect(preview.space.categories.single.channels.map((c) => c.name), [
      'general',
      'oven',
    ]);
    expect(
      preview.space.categories.single.channels.last.kind,
      ChannelKind.voice,
    );
    expect(preview.space.categories.single.channels.first.joined, isFalse);
    expect(directory.viaFor('!bakers:loaf.moe'), ['loaf.moe']);
  });

  test('a matrix.to room-id link looks up and joins via its servers', () async {
    final api = _Api();
    api.hierarchyPages['!bakers:loaf.moe'] = [
      {
        'rooms': [hierarchyChunk('!bakers:loaf.moe', name: 'Bakers')],
      },
    ];
    final client = await _client(api: api);
    final directory = MatrixSpaceDirectory(client);

    final preview = await directory.lookUp(
      'https://matrix.to/#/!bakers:loaf.moe?via=loaf.moe&via=matrix.org',
    );
    await _settle();

    expect(preview.space.id, '!bakers:loaf.moe');
    expect(directory.viaFor('!bakers:loaf.moe'), ['loaf.moe', 'matrix.org']);
  });

  test('nothing there is SpaceNotFound', () async {
    final api = _Api()..aliasNotFound = true;
    final client = await _client(api: api);
    final directory = MatrixSpaceDirectory(client);

    await expectLater(
      directory.lookUp('#nowhere:loaf.moe'),
      throwsA(isA<SpaceNotFound>()),
    );
  });
}
