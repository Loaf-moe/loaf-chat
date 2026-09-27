/// The account's rooms read from the SDK: [Rooms] over the app's one
/// [Client]. Nothing is kept but one snapshot derived from the client's own
/// rooms, rebuilt after every sync — the SDK is the store.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
// The SDK has a Presence and a Timeline of its own; loaf's are the ones the
// UI draws.
import 'package:matrix/matrix.dart' hide Presence, Timeline;

import '../ui/channel/timeline.dart';
import '../ui/members/presence.dart';
import '../ui/model/models.dart';
import '../ui/rooms/rooms.dart';
import '../ui/spaces/add_space.dart' show spaceColorFor;

/// `m.room.create` types that make a room a voice channel: Element's video
/// rooms, stable and unstable.
const _voiceTypes = {'m.call', 'org.matrix.msc3417.call'};

class MatrixRooms extends ChangeNotifier implements Rooms {
  MatrixRooms(this.client) {
    _subscriptions = [
      // After the rooms and account data of a sync are applied, including
      // syncs the SDK makes up itself (a leave the server has forgotten).
      // `SyncStatus.finished` would miss those.
      client.onSync.stream.listen((_) {
        _synced = true;
        _progress = null;
        _rebuild();
      }),
      client.onSyncStatus.stream.listen(_onStatus),
    ];
    // A restored session has synced before; its rooms are already here.
    _synced = client.prevBatch != null;
    _rebuild();
    // The status stream does not replay: a sync already under way when the
    // shell opens is read from its last value.
    final status = client.onSyncStatus.value;
    if (status != null) _onStatus(status);
    unawaited(_loadMe());
  }

  final Client client;

  late final List<StreamSubscription<Object?>> _subscriptions;
  var _disposed = false;

  var _synced = false;
  double? _progress;
  var _spaces = <Space>[];
  var _home = <Channel>[];
  var _invites = <Invite>[];
  String? _myName;

  /// Invites being answered, so a second tap or a stale preview sends
  /// nothing more.
  final _answering = <String, Future<void>>{};

  /// Invites the server has taken an answer to, whose change of membership
  /// has not come down a sync yet. Until it does the room still reads as an
  /// invite; listing it would offer a second answer, and a decline then
  /// leaves the room just joined.
  final _answered = <String>{};

  /// Rooms whose member lists have been asked for. Once each: the shell
  /// asks on every build, and later changes to a loaded list arrive over
  /// sync.
  final _membersAsked = <String>{};

  /// Invites whose own membership event and inviter have been asked of the
  /// database. Once each: after a relaunch only a room list's state is in
  /// memory, and an invite's `is_direct` and sender live in that event.
  final _invitesLoaded = <String>{};

  @override
  Set<RoomAbility> get abilities => const {RoomAbility.answerInvites};

  @override
  bool get synced => _synced;

  @override
  double? get syncProgress => _progress;

  @override
  Member get me {
    final id = client.userID ?? '';
    return Member(
      id,
      _myName ?? id.localpart ?? id,
      spaceColorFor(id),
      presence: Presence.unknown,
    );
  }

  @override
  List<Space> get spaces => _spaces;

  @override
  List<Channel> get homeRooms => _home;

  @override
  List<Invite> get invites => _invites;

  void _onStatus(SyncStatusUpdate update) {
    if (_synced) return;
    final progress = update.status == SyncStatus.processing
        ? update.progress
        : null;
    if (progress == _progress) return;
    _progress = progress;
    _notify();
  }

  Future<void> _loadMe() async {
    try {
      final profile = await client.fetchOwnProfile();
      // A blank name is no name: the localpart reads better than nothing.
      final name = profile.displayName?.trim();
      _myName = name == null || name.isEmpty ? null : profile.displayName;
      _notify();
    } on Object {
      // Offline, or no profile: the localpart stands in.
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ── Mapping ────────────────────────────────────────────────────────────

  void _rebuild() {
    final joined = {
      for (final room in client.rooms)
        if (room.membership == Membership.join) room.id: room,
    };
    final spaces = [
      for (final room in joined.values)
        if (room.isSpace) room,
    ];
    // Every room some joined space lists, at any depth. Those are a
    // space's; Home has what is left.
    final childIds = {
      for (final space in spaces)
        for (final child in space.spaceChildren) ?child.roomId,
    };

    _spaces = [
      for (final space in spaces)
        if (!childIds.contains(space.id)) _space(space, joined),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    _home = [
      for (final room in joined.values)
        if (!room.isSpace && (room.isDirectChat || !childIds.contains(room.id)))
          _channel(room, home: true),
    ];

    // An answer's sync has landed once the room is no longer an invite.
    _answered.removeWhere(
      (id) => client.getRoomById(id)?.membership != Membership.invite,
    );
    _invites = [
      for (final room in client.rooms)
        if (room.membership == Membership.invite &&
            !_answered.contains(room.id))
          _invite(room),
    ];
    for (final room in client.rooms) {
      if (room.membership == Membership.invite) _loadInvite(room);
    }
    _notify();
  }

  /// Brings back an invite's own membership event and its inviter, which a
  /// relaunch leaves on disk: without them a DM invite reads as a room, the
  /// inviter as nobody, and accepting skips `m.direct`. The SDK's own
  /// `loadHeroUsers` does exactly this for invites, from the database first.
  void _loadInvite(Room room) {
    if (!_invitesLoaded.add(room.id)) return;
    unawaited(
      room
          .loadHeroUsers()
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() {
            if (!_disposed) _rebuild();
          }),
    );
  }

  Space _space(Room space, Map<String, Room> joined) {
    final name = space.getLocalizedDisplayname();
    final top = <Channel>[];
    final categories = <ChannelCategory>[];
    for (final child in space.spaceChildren) {
      final room = joined[child.roomId];
      if (room == null) continue; // Not joined: phase 5 lists these.
      if (room.isSpace) {
        final channels = [
          for (final r in _descendants(room, joined, {space.id})) _channel(r),
        ];
        categories.add(
          ChannelCategory(room.getLocalizedDisplayname(), channels),
        );
      } else {
        top.add(_channel(room));
      }
    }
    return Space(
      id: space.id,
      name: name,
      color: spaceColorFor(name),
      categories: [if (top.isNotEmpty) ChannelCategory('', top), ...categories],
      members: _members(space),
    );
  }

  /// A category's rooms: its joined non-space children, then those of any
  /// subspaces under it, flattened in. [seen] stops a space that lists an
  /// ancestor from looping, and a room listed under two of the category's
  /// subspaces from appearing in it twice.
  Iterable<Room> _descendants(
    Room space,
    Map<String, Room> joined,
    Set<String> seen,
  ) sync* {
    if (!seen.add(space.id)) return;
    for (final child in space.spaceChildren) {
      final room = joined[child.roomId];
      if (room == null) continue;
      if (room.isSpace) {
        yield* _descendants(room, joined, seen);
      } else if (seen.add(room.id)) {
        yield room;
      }
    }
  }

  Channel _channel(Room room, {bool home = false}) {
    final type = room
        .getState(EventTypes.RoomCreate)
        ?.content
        .tryGet<String>('type');
    final kind = _voiceTypes.contains(type)
        ? ChannelKind.voice
        : !home
        ? ChannelKind.text
        : room.isDirectChat
        ? ChannelKind.direct
        : ChannelKind.room;
    final topic = room.topic;
    final favourite = room.tags[TagType.favourite];
    return Channel(
      id: room.id,
      name: room.getLocalizedDisplayname(),
      kind: kind,
      unread: room.notificationCount,
      mentions: room.highlightCount,
      private: const {
        JoinRules.invite,
        JoinRules.knock,
      }.contains(room.joinRules),
      topic: topic.isEmpty ? null : topic,
      muted: room.pushRuleState != PushRuleState.notify,
      members: switch (kind) {
        ChannelKind.direct => _others(room),
        ChannelKind.room => _members(room),
        _ => const [],
      },
      favourite: favourite != null,
      favouriteOrder: favourite?.order,
      lowPriority: room.isLowPriority,
      lastActivity: room.latestEventReceivedTime,
    );
  }

  /// Whoever the room has in memory; [loadMembers] fills in the rest.
  List<Member> _members(Room room) => [
    for (final user in room.getParticipants([Membership.join]))
      _member(room, user.id),
  ];

  /// Everyone in a DM but you. The server names them in the room summary
  /// (`m.heroes`) without loading the member list; failing that, `m.direct`
  /// says who a 1:1 is with. That one person is what folds duplicate DMs
  /// into one row, so it must not depend on members having loaded.
  List<Member> _others(Room room) {
    final heroes = room.summary.mHeroes ?? const <String>[];
    final ids = heroes.isNotEmpty ? heroes : [?room.directChatMatrixID];
    return [
      for (final id in ids)
        if (id != client.userID) _member(room, id),
    ];
  }

  Member _member(Room room, String userId) => Member(
    userId,
    room.unsafeGetUserFromMemoryOrFallback(userId).calcDisplayname(),
    spaceColorFor(userId),
    presence: Presence.unknown,
    powerLevel: room.getPowerLevelByUserId(userId).level,
  );

  Invite _invite(Room room) {
    final myId = client.userID ?? '';
    final inviterId = room.getState(EventTypes.RoomMember, myId)?.senderId;
    final inviter = inviterId == null
        ? null
        : room.unsafeGetUserFromMemoryOrFallback(inviterId);
    final name = room.getLocalizedDisplayname();
    final kind = room.isSpace
        ? InviteKind.space
        : room.isDirectChat
        ? InviteKind.direct
        : InviteKind.room;
    final topic = room.topic;
    final count = room.summary.mJoinedMemberCount;
    return Invite(
      id: room.id,
      kind: kind,
      name: name,
      inviter: Member(
        inviterId ?? '',
        inviter?.calcDisplayname() ?? inviterId?.localpart ?? 'someone',
        spaceColorFor(inviterId ?? ''),
        presence: Presence.unknown,
      ),
      color: spaceColorFor(name),
      topic: topic.isEmpty ? null : topic,
      memberCount: count == null || count == 0 ? null : count,
      // What the shell opens once accepted. The room itself arrives with
      // the next sync; until then the shell's fallback holds its place.
      room: kind == InviteKind.space
          ? null
          : Channel(
              id: room.id,
              name: name,
              kind: kind == InviteKind.direct
                  ? ChannelKind.direct
                  : ChannelKind.room,
            ),
      space: kind == InviteKind.space
          ? Space(id: room.id, name: name, color: spaceColorFor(name))
          : null,
    );
  }

  // ── Invites ────────────────────────────────────────────────────────────

  @override
  Future<void> accept(Invite invite) => _answer(invite, (room) => room.join());

  @override
  Future<void> decline(Invite invite) =>
      _answer(invite, (room) => room.leave());

  Future<void> _answer(Invite invite, Future<void> Function(Room) call) {
    // A second tap, or a stale preview, gets the answer already on its way
    // rather than sending another.
    final pending = _answering[invite.id];
    if (pending != null) return pending;
    final room = client.getRoomById(invite.id);
    // Answered already, here or on another device.
    if (room == null ||
        room.membership != Membership.invite ||
        _answered.contains(invite.id)) {
      return Future.value();
    }
    final answer = call(room)
        .then((_) {
          _answered.add(invite.id);
          if (!_disposed) _rebuild();
        })
        // A block body: `remove` returns this very future, and
        // `whenComplete` would wait on it, which never finishes.
        .whenComplete(() {
          _answering.remove(invite.id);
        });
    _answering[invite.id] = answer;
    return answer;
  }

  // ── Not wired yet ──────────────────────────────────────────────────────

  @override
  void loadMembers(String roomId) {
    final room = client.getRoomById(roomId);
    if (room == null || room.participantListComplete) return;
    if (!_membersAsked.add(roomId)) return;
    // A read into the SDK's own store: members it has on disk first, then
    // the server's list, kept in memory (`cache`) so the next snapshot has
    // them. A late or failed answer only leaves the list as it was, until
    // the app next opens.
    unawaited(
      room
          .requestParticipants([Membership.join], true, true)
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() {
            if (!_disposed) _rebuild();
          }),
    );
  }

  @override
  Timeline? timeline(String roomId) => null;

  Never _unwired(String what) =>
      throw UnsupportedError('$what is not wired to the SDK yet');

  @override
  void markRead(String roomId) => _unwired('marking read');
  @override
  void setMuted(String roomId, bool muted) => _unwired('muting');
  @override
  void setJoined(String roomId, bool joined) => _unwired('joining');
  @override
  void setFavourite(String roomId, bool favourite) => _unwired('tagging');
  @override
  void reorderFavourites(List<String> roomIds) => _unwired('tagging');
  @override
  void setLowPriority(String roomId, bool lowPriority) => _unwired('tagging');
  @override
  void joinSpace(Space space) => _unwired('joining a space');
  @override
  String createSpace(String name, {required Member me}) =>
      _unwired('creating a space');
  @override
  Channel createDirect(List<Member> members) => _unwired('starting a DM');

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    super.dispose();
  }
}
