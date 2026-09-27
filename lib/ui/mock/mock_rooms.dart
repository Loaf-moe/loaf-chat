/// [Rooms] played from fixtures, with this session's changes layered over
/// them — the mock's stand-in for membership, read markers, push rules and
/// room tags arriving over sync. Every action works, and none outlives the
/// app.
library;

import 'package:flutter/foundation.dart';

import '../channel/timeline_controller.dart';
import '../rooms/rooms.dart';
import '../spaces/add_space.dart' show spaceColorFor;
import 'fixtures.dart';

class MockRooms extends ChangeNotifier implements Rooms {
  // This session's changes, layered over the fixtures by Space.withSession.
  final _membership = <String, bool>{};
  final _muted = <String, bool>{};
  final _read = <String>{};

  // Home's room tags, as this session has them. Favourites are a list so
  // their order is the list's; m.favourite's `order` is its position.
  final _favourites = [
    for (final room in [
      ...mockHomeRooms,
    ]..sort((a, b) => (a.favouriteOrder ?? 1).compareTo(b.favouriteOrder ?? 1)))
      if (room.favourite) room.id,
  ];
  final _lowPriority = <String, bool>{};

  /// When a room joined or made this session last saw activity.
  final _activity = <String, DateTime>{};

  // Invites answered this session, and what accepting them brought in.
  final _answeredInvites = <String>{};
  final _acceptedRooms = <Channel>[];
  final _acceptedSpaces = <Space>[];

  /// The original spaces' channels share one conversation; every other
  /// room, Home's and anything joined or made this session, has its own.
  late final _shared = TimelineController(mockTimeline(), you: currentUser);
  final _timelines = <String, TimelineController>{};

  var _made = 0;
  var _started = 0;

  @override
  Set<RoomAbility> get abilities => RoomAbility.values.toSet();

  @override
  bool get synced => true;

  @override
  double? get syncProgress => null;

  @override
  Member get me => currentUser;

  /// With this session's reading applied, so badges recount. A left
  /// invite-only channel is dropped: only channels you could join in one
  /// tap are ever listed.
  @override
  List<Space> get spaces => [
    for (final space in [...mockSpaces, ..._acceptedSpaces])
      space.withSession(membership: _membership, muted: _muted, read: _read),
  ];

  /// Home's rooms with this session's tags, mutes and reading applied.
  /// Rooms you have left are gone: Home has no "join" pills, only what you
  /// are in.
  @override
  List<Channel> get homeRooms => [
    for (final room in [...mockHomeRooms, ..._acceptedRooms])
      if (_membership[room.id] != false)
        room.copyWith(
          favourite: _favourites.contains(room.id),
          favouriteOrder: _favourites.contains(room.id)
              ? _favourites.indexOf(room.id) / _favourites.length
              : null,
          lowPriority: _lowPriority[room.id],
          lastActivity: _activity[room.id],
          muted: _muted[room.id],
          // Read state is applied per room here, before duplicates fold
          // together, so an older room's unreads still count on the row.
          unread: _read.contains(room.id) ? 0 : room.unread,
          mentions: _read.contains(room.id) ? 0 : room.mentions,
        ),
  ];

  @override
  List<Invite> get invites => [
    for (final invite in mockInvites)
      if (!_answeredInvites.contains(invite.id)) invite,
  ];

  /// The fixtures carry their members whole.
  @override
  void loadMembers(String roomId) {}

  void _change(VoidCallback change) {
    change();
    notifyListeners();
  }

  @override
  void markRead(String roomId) {
    if (_read.contains(roomId)) return;
    _change(() => _read.add(roomId));
  }

  @override
  void setMuted(String roomId, bool muted) =>
      _change(() => _muted[roomId] = muted);

  @override
  void setJoined(String roomId, bool joined) =>
      _change(() => _membership[roomId] = joined);

  /// A new favourite goes last.
  @override
  void setFavourite(String roomId, bool favourite) => _change(() {
    _favourites.remove(roomId);
    if (favourite) _favourites.add(roomId);
  });

  @override
  void reorderFavourites(List<String> roomIds) => _change(
    () => _favourites
      ..clear()
      ..addAll(roomIds),
  );

  @override
  void setLowPriority(String roomId, bool lowPriority) =>
      _change(() => _lowPriority[roomId] = lowPriority);

  /// A DM or room joins Home, newest; a space joins the rail. Answered at
  /// once, so callers carry on in the same frame.
  @override
  Future<void> accept(Invite invite) {
    _change(() {
      _answeredInvites.add(invite.id);
      final room = invite.room;
      final space = invite.space;
      if (room != null) {
        _acceptedRooms.add(room);
        _activity[room.id] = DateTime.now();
      } else if (space != null) {
        _acceptedSpaces.add(space);
      }
    });
    return SynchronousFuture(null);
  }

  @override
  Future<void> decline(Invite invite) {
    _change(() => _answeredInvites.add(invite.id));
    return SynchronousFuture(null);
  }

  /// Joining a space you were invited to answers the invite.
  @override
  void joinSpace(Space space) => _change(() {
    _acceptedSpaces.add(space);
    for (final invite in mockInvites) {
      if (invite.space?.id == space.id) _answeredInvites.add(invite.id);
    }
  });

  /// The mock's space creation: the space room, then #general and a voice
  /// channel as its children, both restricted to its members.
  @override
  String createSpace(String name, {required Member me}) {
    final id = 'made-${_made++}';
    _change(
      () => _acceptedSpaces.add(
        Space(
          id: id,
          name: name,
          color: spaceColorFor(name),
          members: [me],
          categories: [
            ChannelCategory('', [
              Channel(id: '$id-general', name: 'general'),
              Channel(
                id: '$id-hangout',
                name: 'hangout',
                kind: ChannelKind.voice,
              ),
            ]),
          ],
        ),
      ),
    );
    return id;
  }

  /// The mock's createRoom: is_direct, trusted_private_chat, the people
  /// invited, and the room added to m.direct.
  @override
  Channel createDirect(List<Member> members) {
    final room = Channel(
      id: 'dm-new-${_started++}',
      name: members.length == 1
          ? members.single.name
          : members.map((m) => m.name.split(' ').first).join(', '),
      kind: ChannelKind.direct,
      members: members,
      waitingFor: members,
    );
    _change(() {
      _acceptedRooms.add(room);
      _activity[room.id] = DateTime.now();
    });
    return room;
  }

  @override
  TimelineController timeline(String roomId) {
    if (mockSpaces.any((s) => s.allChannels.any((c) => c.id == roomId))) {
      return _shared;
    }
    return _timelines.putIfAbsent(roomId, () {
      final home = [
        ...mockHomeRooms,
        ..._acceptedRooms,
      ].any((c) => c.id == roomId);
      final timeline = TimelineController(
        home ? mockHomeTimeline(roomId) : mockSpaceTimeline(roomId),
        you: currentUser,
      );
      var count = timeline.messages.length;
      // A new message moves a DM up the list.
      timeline.addListener(() {
        if (timeline.messages.length > count) {
          _change(() => _activity[roomId] = DateTime.now());
        }
        count = timeline.messages.length;
      });
      return timeline;
    });
  }

  @override
  void dispose() {
    _shared.dispose();
    for (final t in _timelines.values) {
      t.dispose();
    }
    super.dispose();
  }
}
