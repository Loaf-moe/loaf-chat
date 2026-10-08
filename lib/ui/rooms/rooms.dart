/// The account's rooms, as the shell draws them: the rail's spaces, each
/// space's channels, Home's rooms and your invites. [MockRooms] plays them
/// from fixtures; `MatrixRooms` maps them from the SDK's sync.
library;

import 'package:flutter/foundation.dart';

import '../channel/timeline.dart';
import '../model/arrival.dart';
import '../model/models.dart';
import '../settings/devices.dart';
import '../shell/profile.dart';
import '../spaces/space_directory.dart';
import '../model/media_source.dart';
import '../widgets/avatar_images.dart';

/// What a backend can do to your rooms yet. The shell draws no control for
/// anything missing: a control that only pretends would lie about your real
/// account, which is still there on relaunch.
enum RoomAbility {
  /// Mark as read, and reading by opening.
  markRead,
  mute,
  leave,

  /// Joining an unjoined channel from its row.
  join,

  /// Favourite and low priority, and reordering favourites.
  tag,

  /// Accepting and declining an invite.
  answerInvites,
  addSpace,
  startDirect,

  /// Inviting people to a room or space.
  invite,

  /// Voice channels and DM calls.
  calls,

  /// Reading a conversation and writing in it.
  messages,

  /// Your presence, status message and profile.
  editProfile,

  /// Listing, renaming and signing out the account's sessions.
  devices,
}

/// The server turned down some of an invite. [failed] maps each user id
/// that did not go through to why, in the server's words.
class InviteRefused implements Exception {
  const InviteRefused(this.failed);
  final Map<String, String> failed;
}

/// Nothing is at that address.
class SpaceNotFound implements Exception {
  const SpaceNotFound();
}

/// A compound action stopped partway. [spaceId] is set when a space was
/// made and still stands; [missing] names what did not happen, in the
/// UI's words ("#general", "hangout", "3 channels").
class PartlyDone implements Exception {
  const PartlyDone({this.spaceId, this.missing = const []});
  final String? spaceId;
  final List<String> missing;
}

abstract interface class Rooms implements Listenable {
  Set<RoomAbility> get abilities;

  /// False until the first sync has landed. A relaunch restores from the
  /// database, so only a fresh sign-in waits on this.
  bool get synced;

  /// How far through handling the first sync's rooms, 0 to 1; null while
  /// still waiting on the server, which says nothing about how long.
  double? get syncProgress;

  /// You, as the rooms know you.
  Member get me;

  /// Turns the avatar refs on this account's people, rooms and spaces into
  /// images.
  AvatarImages get avatarImages;

  /// Turns the media on this account's messages into pictures and files on
  /// disk, the way [avatarImages] does for avatars.
  MediaSource get media;

  /// Your presence and status, and everyone else's. The rooms own it and
  /// dispose of it with themselves.
  Profile get profile;

  /// Your signed-in sessions. Like [profile], the rooms own it and dispose
  /// of it with themselves.
  Devices get devices;

  /// The rail, in order.
  List<Space> get spaces;

  /// New messages that the push rules say should notify you, as they
  /// arrive. Never the backlog a launch catches up on.
  Stream<Arrival> get arrivals;

  /// Everything that lives in Home, before `homeSections` sorts it.
  List<Channel> get homeRooms;

  List<Invite> get invites;

  /// Asks for a room's full member list, where the backend loaded only
  /// some of it. Listeners hear when it arrives.
  void loadMembers(String roomId);

  /// A room's conversation, or null where this backend has no
  /// [RoomAbility.messages]. The same one comes back each time; the rooms
  /// dispose of it when they are disposed.
  Timeline? timeline(String roomId);

  void markRead(String roomId);
  Future<void> setMuted(String roomId, bool muted);
  Future<void> setJoined(String roomId, bool joined);
  Future<void> setFavourite(String roomId, bool favourite);

  /// Favourites in this order, first to last.
  Future<void> reorderFavourites(List<String> roomIds);
  Future<void> setLowPriority(String roomId, bool lowPriority);

  /// Throws when the server says no; the invite then stays.
  Future<void> accept(Invite invite);
  Future<void> decline(Invite invite);

  Future<void> joinSpace(Space space);

  /// Leaves the space and every joined room inside it that no other joined
  /// space lists. Throws [PartlyDone] if any refused.
  Future<void> leaveSpace(String spaceId);

  /// Returns the new space's id. Throws [PartlyDone] (with its id) when the
  /// space stands but a channel is missing.
  Future<String> createSpace(String name, {required Member me});

  /// Returns the DM, which is already in [homeRooms]: an existing one with
  /// exactly these people, or a new one.
  Future<Channel> createDirect(List<Member> members);

  /// Throws [InviteRefused] naming who did not go through.
  Future<void> invite(String roomId, List<String> userIds);

  SpaceDirectory get directory;

  void dispose();
}
