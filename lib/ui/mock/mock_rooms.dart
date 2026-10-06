/// [Rooms] played from fixtures, with this session's changes layered over
/// them — the mock's stand-in for membership, read markers, push rules and
/// room tags arriving over sync. Every action works, and none outlives the
/// app.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../channel/timeline_controller.dart';
import '../model/media_source.dart';
import '../rooms/rooms.dart';
import '../settings/devices.dart';
import '../shell/profile.dart';
import '../spaces/add_space.dart' show spaceColorFor;
import '../spaces/space_directory.dart';
import '../widgets/avatar_images.dart';
import 'fixtures.dart';
import 'mock_devices.dart';
import 'mock_media_source.dart';
import 'mock_profile.dart';
import 'mock_space_directory.dart';

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
  late final _shared = TimelineController(
    mockTimeline(),
    you: currentUser,
    uploadLimit: _uploadLimit,
  );
  final _timelines = <String, TimelineController>{};

  /// loaf.moe's, so a big video is turned away here as it would be there.
  static const _uploadLimit = 20000000;

  var _made = 0;
  var _started = 0;

  @override
  final SpaceDirectory directory = MockSpaceDirectory();

  @override
  AvatarImages get avatarImages => const NoAvatarImages();

  /// Made on first use, so a session with no media never touches the disk.
  Directory? _mediaDir;

  @override
  late final MediaSource media = MockMediaSource(
    _mediaDir = Directory.systemTemp.createTempSync('loaf-mock-media'),
  );

  @override
  final Profile profile = MockProfile();

  @override
  final Devices devices = MockDevices();

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
  /// Spaces you have left this session are gone, the same way a left Home
  /// room is: [_membership] carries the space's own id as well as its
  /// channels'.
  @override
  List<Space> get spaces => [
    for (final space in [...mockSpaces, ..._acceptedSpaces])
      if (_membership[space.id] != false)
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
  Future<void> setMuted(String roomId, bool muted) {
    _change(() => _muted[roomId] = muted);
    return SynchronousFuture(null);
  }

  @override
  Future<void> setJoined(String roomId, bool joined) {
    _change(() => _membership[roomId] = joined);
    return SynchronousFuture(null);
  }

  /// A new favourite goes last.
  @override
  Future<void> setFavourite(String roomId, bool favourite) {
    _change(() {
      _favourites.remove(roomId);
      if (favourite) _favourites.add(roomId);
    });
    return SynchronousFuture(null);
  }

  @override
  Future<void> reorderFavourites(List<String> roomIds) {
    _change(
      () => _favourites
        ..clear()
        ..addAll(roomIds),
    );
    return SynchronousFuture(null);
  }

  @override
  Future<void> setLowPriority(String roomId, bool lowPriority) {
    _change(() => _lowPriority[roomId] = lowPriority);
    return SynchronousFuture(null);
  }

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

  /// Joining a space you were invited to answers the invite. Joining a
  /// space you had left clears its own left mark, but not its channels':
  /// a space rejoined starts as empty as a freshly joined one, and each
  /// channel is joined on its own, same as any other unjoined channel. A
  /// space already known — a fixture, or accepted earlier this session —
  /// is not added a second time, so rejoining never duplicates its row.
  @override
  Future<void> joinSpace(Space space) {
    _change(() {
      final known = [
        ...mockSpaces,
        ..._acceptedSpaces,
      ].any((s) => s.id == space.id);
      if (!known) _acceptedSpaces.add(space);
      _membership[space.id] = true;
      for (final invite in mockInvites) {
        if (invite.space?.id == space.id) _answeredInvites.add(invite.id);
      }
    });
    return SynchronousFuture(null);
  }

  /// Leaves the space at once: a space made or joined this session is
  /// dropped from [_acceptedSpaces], and an original fixture space is
  /// marked left the same way a Home room is, by its own id in
  /// [_membership]. Either way every one of its channels is marked left
  /// too, so rejoining the space starts fresh.
  @override
  Future<void> leaveSpace(String spaceId) {
    _change(() {
      final target = [
        ...mockSpaces,
        ..._acceptedSpaces,
      ].firstWhere((s) => s.id == spaceId);
      for (final channel in target.allChannels) {
        _membership[channel.id] = false;
      }
      if (!_acceptedSpaces.remove(target)) {
        _membership[spaceId] = false;
      }
    });
    return SynchronousFuture(null);
  }

  /// The mock's space creation: the space room, then #general and a voice
  /// channel as its children, both restricted to its members.
  @override
  Future<String> createSpace(String name, {required Member me}) {
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
    return SynchronousFuture(id);
  }

  /// The mock's createRoom: is_direct, trusted_private_chat, the people
  /// invited, and the room added to m.direct.
  @override
  Future<Channel> createDirect(List<Member> members) {
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
    return SynchronousFuture(room);
  }

  /// The mock answers at once and never refuses.
  @override
  Future<void> invite(String roomId, List<String> userIds) =>
      SynchronousFuture(null);

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
        uploadLimit: _uploadLimit,
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
    profile.dispose();
    devices.dispose();
    _shared.dispose();
    _mediaDir?.deleteSync(recursive: true);
    for (final t in _timelines.values) {
      t.dispose();
    }
    super.dispose();
  }
}
