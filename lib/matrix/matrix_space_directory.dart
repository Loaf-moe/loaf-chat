/// Finding spaces you have not joined yet: a server's public directory, or
/// an address someone shared. Remembers each preview's via servers, keyed
/// by space id, so [MatrixRooms.joinSpace] can join through them.
library;

import 'package:matrix/matrix.dart';

import '../ui/model/models.dart';
import '../ui/rooms/rooms.dart' show SpaceNotFound;
import '../ui/spaces/add_space.dart' show spaceColorFor;
import '../ui/spaces/space_address.dart';
import '../ui/spaces/space_directory.dart';

/// `m.room.create` types that make a room a voice channel.
const _voiceTypes = {'m.call', 'org.matrix.msc3417.call'};

class MatrixSpaceDirectory implements SpaceDirectory {
  MatrixSpaceDirectory(this.client);

  final Client client;

  /// The via servers of the last preview served for each space id, so
  /// [MatrixRooms.joinSpace] can join through them without [SpacePreview]
  /// or [Rooms] carrying them.
  final _via = <String, List<String>>{};

  /// The via servers of the last preview served for [spaceId], or none.
  List<String> viaFor(String spaceId) => _via[spaceId] ?? const [];

  @override
  Future<List<SpacePreview>> publicSpaces(String server) async {
    final response = await client.queryPublicRooms(
      server: server,
      filter: PublicRoomQueryFilter(roomTypes: ['m.space']),
    );
    return [for (final chunk in response.chunk) _fromChunk(chunk, server)];
  }

  SpacePreview _fromChunk(PublishedRoomsChunk chunk, String server) {
    final id = chunk.roomId;
    final name = chunk.name ?? chunk.canonicalAlias ?? 'unnamed';
    // The listing came from [server], so it certainly knows the space. A
    // via a lookup already saved is at least as good: keep it.
    if (_via[id]?.isEmpty ?? true) _via[id] = [server];
    return SpacePreview(
      alias: chunk.canonicalAlias ?? id,
      space: Space(id: id, name: name, color: spaceColorFor(name)),
      topic: chunk.topic,
      memberCount: chunk.numJoinedMembers,
      inviteOnly: chunk.joinRule == 'invite',
    );
  }

  @override
  Future<SpacePreview> lookUp(String address) async {
    final parsed = parseSpaceAddress(address);
    if (parsed == null) throw const SpaceNotFound();

    final String id;
    List<String> via;
    if (parsed.startsWith('#')) {
      try {
        final resolved = await client.getRoomIdByAlias(parsed);
        final roomId = resolved.roomId;
        if (roomId == null) throw const SpaceNotFound();
        id = roomId;
        via = resolved.servers ?? const [];
      } on MatrixException catch (e) {
        if (e.errcode == 'M_NOT_FOUND') throw const SpaceNotFound();
        rethrow;
      }
    } else {
      id = parsed;
      via = _linkVia(address);
    }

    try {
      final rooms = <SpaceRoomsChunk$2>[];
      String? from;
      do {
        final page = await client.getSpaceHierarchy(
          id,
          maxDepth: 1,
          limit: 50,
          from: from,
        );
        rooms.addAll(page.rooms);
        from = page.nextBatch;
      } while (from != null);
      if (rooms.isEmpty) throw const SpaceNotFound();

      final head = rooms.first;
      final name = head.name ?? head.canonicalAlias ?? 'unnamed';
      final channels = [for (final chunk in rooms.skip(1)) _channelFrom(chunk)];
      _via[id] = via;
      return SpacePreview(
        alias: head.canonicalAlias ?? id,
        space: Space(
          id: id,
          name: name,
          color: spaceColorFor(name),
          categories: [if (channels.isNotEmpty) ChannelCategory('', channels)],
        ),
        topic: head.topic,
        memberCount: head.numJoinedMembers,
        inviteOnly: head.joinRule == 'invite',
      );
    } on MatrixException catch (e) {
      if (e.errcode == 'M_NOT_FOUND') throw const SpaceNotFound();
      rethrow;
    }
  }

  Channel _channelFrom(SpaceRoomsChunk$2 chunk) => Channel(
    id: chunk.roomId,
    name: chunk.name ?? chunk.canonicalAlias ?? 'unnamed',
    kind: _voiceTypes.contains(chunk.roomType)
        ? ChannelKind.voice
        : ChannelKind.text,
    joined: false,
    topic: chunk.topic,
    private: const {'invite', 'knock'}.contains(chunk.joinRule),
  );

  /// A matrix.to link's `?via=` query parameters, repeated as many times as
  /// the link carries them. Not a space address itself, so
  /// [parseSpaceAddress] strips it before this ever sees the parsed id.
  List<String> _linkVia(String input) {
    final link = RegExp(
      r'^(?:https?://)?matrix\.to/#/(.+)$',
      caseSensitive: false,
    ).firstMatch(input.trim());
    if (link == null) return const [];
    final rest = link.group(1)!;
    final qIndex = rest.indexOf('?');
    if (qIndex == -1) return const [];
    try {
      return Uri(query: rest.substring(qIndex + 1)).queryParametersAll['via'] ??
          const [];
    } on FormatException {
      return const [];
    }
  }
}
