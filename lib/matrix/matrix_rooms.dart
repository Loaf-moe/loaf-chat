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
import '../ui/spaces/space_directory.dart';
import 'matrix_hierarchy.dart';
import 'matrix_timeline.dart';

/// `m.room.create` types that make a room a voice channel: Element's video
/// rooms, stable and unstable.
const _voiceTypes = {'m.call', 'org.matrix.msc3417.call'};

/// What a row should show while its change is on its way. A field is
/// cleared when a sync shows it, or when its call fails.
class _Wish {
  bool? muted;
  bool? favourite;
  double? favouriteOrder;
  bool? lowPriority;
  bool? joined;
  bool get isEmpty =>
      muted == null &&
      favourite == null &&
      favouriteOrder == null &&
      lowPriority == null &&
      joined == null;
}

class MatrixRooms extends ChangeNotifier implements Rooms {
  MatrixRooms(this.client) {
    _hierarchy = MatrixHierarchy(
      client,
      onChange: () {
        if (!_disposed) _rebuild();
      },
    );
    _subscriptions = [
      // After the rooms and account data of a sync are applied, including
      // syncs the SDK makes up itself (a leave the server has forgotten).
      // `SyncStatus.finished` would miss those.
      client.onSync.stream.listen(_onSync),
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

  /// A space's children the SDK doesn't have state for: unjoined channels,
  /// and the children of an unjoined subspace. The hierarchy cache: the
  /// other of the two small maps `MatrixRooms` keeps beside its derived
  /// snapshot.
  late final MatrixHierarchy _hierarchy;

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

  /// Each room's conversation, once opened. They stay open until the rooms
  /// are disposed: fine at loaf.moe's size.
  final _timelines = <String, MatrixTimeline>{};

  /// Rooms whose read marker is on its way, and those that saw more since
  /// it left: one receipt at a time per room, however fast messages come.
  final _reading = <String>{};
  final _readAgain = <String>{};

  /// Each room's pending change of mute, tag or membership, drawn on top of
  /// the SDK's own state until a sync agrees or the call fails. The pending
  /// overlay: one of the two small maps `MatrixRooms` keeps beside its
  /// derived snapshot.
  final _wishes = <String, _Wish>{};

  /// Each (room, field)'s latest wish, so a failed older call doesn't undo
  /// a newer one.
  final _generation = <(String, String), int>{};

  @override
  Set<RoomAbility> get abilities => const {
    RoomAbility.answerInvites,
    RoomAbility.messages,
    RoomAbility.markRead,
    RoomAbility.mute,
    RoomAbility.tag,
    RoomAbility.join,
    RoomAbility.leave,
  };

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

  /// After the rooms and account data of a sync are applied, including
  /// syncs the SDK makes up itself (a leave the server has forgotten).
  /// `SyncStatus.finished` would miss those. Also invalidates a joined
  /// space's cached hierarchy when this sync shows its children changed.
  void _onSync(SyncUpdate update) {
    update.rooms?.join?.forEach((roomId, room) {
      final changed =
          (room.state?.any((e) => e.type == EventTypes.SpaceChild) ?? false) ||
          (room.timeline?.events?.any((e) => e.type == EventTypes.SpaceChild) ??
              false);
      if (changed) _hierarchy.invalidateContaining(roomId);
    });
    _synced = true;
    _progress = null;
    _rebuild();
  }

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
    _settleWishes();
    final joined = {
      for (final room in client.rooms)
        if (room.membership == Membership.join &&
            _wishes[room.id]?.joined != false)
          room.id: room,
    };
    // A join wished but not yet synced: drawn as joined from wherever its
    // room now lists it. Task 4 fills in the case where there is no [Room]
    // object yet (an unjoined hierarchy child).
    for (final entry in _wishes.entries) {
      if (entry.value.joined == true && !joined.containsKey(entry.key)) {
        final room = client.getRoomById(entry.key);
        if (room != null) joined[entry.key] = room;
      }
    }
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

  /// Clears every wished field whose server value now matches it, and drops
  /// any wish left empty. Called at the start of [_rebuild], so a sync that
  /// agrees with a wish lets the server's own state, including a later
  /// change from elsewhere, show through again.
  void _settleWishes() {
    for (final id in _wishes.keys.toList()) {
      final wish = _wishes[id]!;
      final room = client.getRoomById(id);
      if (wish.muted != null &&
          room != null &&
          (room.pushRuleState != PushRuleState.notify) == wish.muted) {
        wish.muted = null;
      }
      if (wish.favourite != null &&
          room != null &&
          (room.tags[TagType.favourite] != null) == wish.favourite) {
        wish.favourite = null;
      }
      if (wish.favouriteOrder != null &&
          room != null &&
          room.tags[TagType.favourite]?.order == wish.favouriteOrder) {
        wish.favouriteOrder = null;
      }
      if (wish.lowPriority != null &&
          room != null &&
          room.isLowPriority == wish.lowPriority) {
        wish.lowPriority = null;
      }
      if (wish.joined != null &&
          (room?.membership == Membership.join) == wish.joined) {
        wish.joined = null;
      }
      if (wish.isEmpty) _wishes.remove(id);
    }
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
    // What `/hierarchy` gave us for this space's whole tree: metadata for
    // an unjoined child, at any depth, that the SDK's own state cannot
    // give — plus the children of an unjoined subspace, whose state the
    // SDK never has at all.
    final chunks = <String, SpaceRoomsChunk$2>{
      for (final chunk in _hierarchy.children(space.id) ?? const [])
        chunk.roomId: chunk,
    };
    final top = <Channel>[];
    final categories = <ChannelCategory>[];
    for (final child in space.spaceChildren) {
      final id = child.roomId;
      if (id == null) continue;
      final room = joined[id];
      final chunk = room == null ? chunks[id] : null;
      if (room == null && chunk == null) continue; // Not joined, not fetched.
      if (room == null && !_hierarchyChildVisible(chunk!, joined)) continue;
      final isSpace = room?.isSpace ?? chunk!.roomType == 'm.space';
      if (isSpace) {
        final channels = _categoryChannels(id, joined, chunks, {
          space.id,
        }).toList();
        final categoryName =
            room?.getLocalizedDisplayname() ?? _chunkName(chunk!);
        categories.add(ChannelCategory(categoryName, channels));
      } else {
        top.add(room != null ? _channel(room) : _hierarchyChannel(chunk!));
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

  /// Whether a hierarchy child is drawn at all: `invite` and `knock` never
  /// are; `restricted` only if some allowed room is one you have joined,
  /// or the chunk doesn't say — the common case, where the immediate
  /// parent (already joined, or this call would not have reached it)
  /// satisfies the rule.
  bool _hierarchyChildVisible(
    SpaceRoomsChunk$2 chunk,
    Map<String, Room> joined,
  ) {
    switch (chunk.joinRule) {
      case 'invite':
      case 'knock':
        return false;
      case 'restricted':
        final allowed = chunk.allowedRoomIds;
        return allowed == null || allowed.any(joined.containsKey);
      default:
        return true;
    }
  }

  /// What a hierarchy chunk is called, absent a room to ask.
  String _chunkName(SpaceRoomsChunk$2 chunk) =>
      chunk.name ?? chunk.canonicalAlias ?? 'unnamed';

  /// An unjoined hierarchy child as a row: only what `/hierarchy` gave us,
  /// plus a `joined: true` wish already sent but not yet synced.
  Channel _hierarchyChannel(SpaceRoomsChunk$2 chunk) {
    final channel = Channel(
      id: chunk.roomId,
      name: _chunkName(chunk),
      kind: _voiceTypes.contains(chunk.roomType)
          ? ChannelKind.voice
          : ChannelKind.text,
      joined: false,
      topic: chunk.topic,
    );
    final wish = _wishes[chunk.roomId];
    if (wish?.joined != true) return channel;
    return channel.copyWith(joined: true);
  }

  /// A category's channels: [id]'s own non-space children — from its own
  /// state if joined, from the cached hierarchy chunk if not — then those
  /// of any subspace under it, joined or not, flattened in. [seen] stops a
  /// space that lists an ancestor from looping, and a room listed under
  /// two of the category's subspaces from appearing in it twice.
  Iterable<Channel> _categoryChannels(
    String id,
    Map<String, Room> joined,
    Map<String, SpaceRoomsChunk$2> chunks,
    Set<String> seen,
  ) sync* {
    if (!seen.add(id)) return;
    final room = joined[id];
    final childIds = room != null
        ? [for (final child in room.spaceChildren) child.roomId]
        : [
            for (final child in chunks[id]?.childrenState ?? const [])
              child.stateKey,
          ];
    for (final childId in childIds) {
      if (childId == null) continue;
      final childRoom = joined[childId];
      final childChunk = childRoom == null ? chunks[childId] : null;
      if (childRoom == null && childChunk == null) continue;
      if (childRoom == null && !_hierarchyChildVisible(childChunk!, joined)) {
        continue;
      }
      final childIsSpace =
          childRoom?.isSpace ?? childChunk!.roomType == 'm.space';
      if (childIsSpace) {
        yield* _categoryChannels(childId, joined, chunks, seen);
      } else if (seen.add(childId)) {
        yield childRoom != null
            ? _channel(childRoom)
            : _hierarchyChannel(childChunk!);
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
    final channel = Channel(
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
    final wish = _wishes[room.id];
    if (wish == null) return channel;
    return channel.copyWith(
      muted: wish.muted,
      favourite: wish.favourite,
      favouriteOrder: wish.favouriteOrder,
      lowPriority: wish.lowPriority,
      joined: wish.joined,
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

  // ── Conversations ──────────────────────────────────────────────────────

  @override
  Timeline? timeline(String roomId) {
    final open = _timelines[roomId];
    if (open != null) return open;
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != Membership.join) return null;
    return _timelines[roomId] = MatrixTimeline(
      room,
      you: me,
      member: (userId) => _member(room, userId),
    );
  }

  /// Moves the fully-read marker and your public receipt to the newest
  /// event the server has. Nothing is zeroed here: the counts drop when
  /// the receipt comes back down a sync. A failed receipt changes nothing,
  /// and the next opening tries again.
  @override
  void markRead(String roomId) {
    final room = client.getRoomById(roomId);
    final last = room?.lastEvent;
    // Your own message still on its way has no event id to mark.
    if (room == null || last == null || !last.status.isSent) return;
    if (room.notificationCount == 0 && room.fullyRead == last.eventId) return;
    if (!_reading.add(roomId)) {
      _readAgain.add(roomId);
      return;
    }
    unawaited(
      room
          .setReadMarker(last.eventId, mRead: last.eventId, public: true)
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() {
            _reading.remove(roomId);
            if (_readAgain.remove(roomId) && !_disposed) markRead(roomId);
          }),
    );
  }

  // ── Toggles ────────────────────────────────────────────────────────────

  /// Applies an optimistic change to [roomId]'s row and sends it to the
  /// server. Shows at once through [set]; [unset] undoes only the fields
  /// this very call owns, so a failure never undoes a newer wish on the
  /// same field. See `_Wish` and the module doc for the design.
  Future<void> _wished(
    String roomId,
    String field,
    void Function(_Wish) set,
    void Function(_Wish) unset,
    Future<void> Function() call,
  ) => _wishedFields(roomId, {field: (set, unset)}, call);

  /// As [_wished], for a call that wishes several fields at once (favourite
  /// and low priority both change with one tag call). Each field keeps its
  /// own generation, so a later call touching only one of them is never
  /// undone by an earlier one failing.
  Future<void> _wishedFields(
    String roomId,
    Map<String, (void Function(_Wish), void Function(_Wish))> fields,
    Future<void> Function() call,
  ) async {
    final wish = _wishes.putIfAbsent(roomId, _Wish.new);
    final mine = <String, int>{};
    fields.forEach((field, fns) {
      fns.$1(wish);
      final key = (roomId, field);
      mine[field] = _generation[key] = (_generation[key] ?? 0) + 1;
    });
    _rebuild();
    try {
      await call();
    } catch (_) {
      final w = _wishes[roomId];
      if (w != null) {
        fields.forEach((field, fns) {
          if (_generation[(roomId, field)] == mine[field]) fns.$2(w);
        });
        if (w.isEmpty) _wishes.remove(roomId);
      }
      if (!_disposed) _rebuild();
      rethrow;
    }
  }

  @override
  Future<void> setMuted(String roomId, bool muted) {
    final room = client.getRoomById(roomId);
    if (room == null) return Future.value();
    return _wished(
      roomId,
      'muted',
      (wish) => wish.muted = muted,
      (wish) => wish.muted = null,
      () => room.setPushRuleState(
        muted ? PushRuleState.dontNotify : PushRuleState.notify,
      ),
    );
  }

  @override
  Future<void> setFavourite(String roomId, bool favourite) {
    final room = client.getRoomById(roomId);
    if (room == null) return Future.value();
    return favourite ? _favouriteOn(room) : _favouriteOff(room);
  }

  Future<void> _favouriteOn(Room room) => _wishedFields(
    room.id,
    {
      'favourite': ((w) => w.favourite = true, (w) => w.favourite = null),
      'lowPriority': (
        (w) => w.lowPriority = false,
        (w) => w.lowPriority = null,
      ),
    },
    () async {
      await room.addTag(TagType.favourite, order: _afterLastFavourite());
      if (room.tags[TagType.lowPriority] != null) {
        await room.removeTag(TagType.lowPriority);
      }
    },
  );

  Future<void> _favouriteOff(Room room) => _wished(
    room.id,
    'favourite',
    (wish) => wish.favourite = false,
    (wish) => wish.favourite = null,
    () => room.removeTag(TagType.favourite),
  );

  /// A little past the highest order any joined room's favourite tag has
  /// now, so a new favourite lands last; 0.5 when there are none yet.
  double _afterLastFavourite() {
    var last = -1.0;
    for (final room in client.rooms) {
      if (room.membership != Membership.join) continue;
      final order = room.tags[TagType.favourite]?.order;
      if (order != null && order > last) last = order;
    }
    return last < 0 ? 0.5 : (last + 1) / 2;
  }

  @override
  Future<void> setLowPriority(String roomId, bool lowPriority) {
    final room = client.getRoomById(roomId);
    if (room == null) return Future.value();
    return lowPriority ? _lowPriorityOn(room) : _lowPriorityOff(room);
  }

  Future<void> _lowPriorityOn(Room room) => _wishedFields(
    room.id,
    {
      'lowPriority': ((w) => w.lowPriority = true, (w) => w.lowPriority = null),
      'favourite': ((w) => w.favourite = false, (w) => w.favourite = null),
    },
    () async {
      await room.addTag(TagType.lowPriority);
      if (room.tags[TagType.favourite] != null) {
        await room.removeTag(TagType.favourite);
      }
    },
  );

  Future<void> _lowPriorityOff(Room room) => _wished(
    room.id,
    'lowPriority',
    (wish) => wish.lowPriority = false,
    (wish) => wish.lowPriority = null,
    () => room.removeTag(TagType.lowPriority),
  );

  /// Favourites in [roomIds]' order, first to last. Only rooms whose
  /// position actually changed are sent, one at a time.
  @override
  Future<void> reorderFavourites(List<String> roomIds) async {
    final n = roomIds.length;
    for (var i = 0; i < n; i++) {
      final room = client.getRoomById(roomIds[i]);
      if (room == null) continue;
      final order = (i + 1) / (n + 1);
      if (room.tags[TagType.favourite]?.order == order) continue;
      await _wished(
        room.id,
        'favouriteOrder',
        (wish) => wish.favouriteOrder = order,
        (wish) => wish.favouriteOrder = null,
        () => room.addTag(TagType.favourite, order: order),
      );
    }
  }

  @override
  Future<void> setJoined(String roomId, bool joined) {
    if (!joined) {
      final room = client.getRoomById(roomId);
      if (room == null) return Future.value();
      return _wished(
        roomId,
        'joined',
        (wish) => wish.joined = false,
        (wish) => wish.joined = null,
        () => room.leave().then((_) => _invalidateHierarchies()),
      );
    }
    return _wished(
      roomId,
      'joined',
      (wish) => wish.joined = true,
      (wish) => wish.joined = null,
      () => client
          .joinRoom(roomId, via: _hierarchy.via(roomId))
          .then((_) => _invalidateHierarchies()),
    );
  }

  /// Every joined space's hierarchy is stale once a room it lists is
  /// joined or left: the child's own join state, or the count of children
  /// left to join, has changed.
  void _invalidateHierarchies() {
    for (final room in client.rooms) {
      if (room.isSpace && room.membership == Membership.join) {
        _hierarchy.invalidate(room.id);
      }
    }
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

  Future<Never> _unwired(String what) =>
      Future.error(UnsupportedError('$what is not wired to the SDK yet'));

  @override
  Future<void> joinSpace(Space space) => _unwired('joining a space');
  @override
  Future<void> leaveSpace(String spaceId) => _unwired('leaving a space');
  @override
  Future<String> createSpace(String name, {required Member me}) =>
      _unwired('creating a space');
  @override
  Future<Channel> createDirect(List<Member> members) =>
      _unwired('starting a DM');
  @override
  Future<void> invite(String roomId, List<String> userIds) =>
      _unwired('inviting');
  @override
  SpaceDirectory get directory =>
      throw UnsupportedError('the space directory is not wired to the SDK yet');

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    for (final t in _timelines.values) {
      t.dispose();
    }
    _hierarchy.dispose();
    super.dispose();
  }
}
