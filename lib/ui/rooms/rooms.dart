/// The account's rooms, as the shell draws them: the rail's spaces, each
/// space's channels, Home's rooms and your invites. [MockRooms] plays them
/// from fixtures; `MatrixRooms` maps them from the SDK's sync.
library;

import 'package:flutter/foundation.dart';

import '../model/models.dart';

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

  /// Voice channels and DM calls.
  calls,

  /// Reading a conversation and writing in it.
  messages,

  /// Your presence, status message and profile.
  editProfile,
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

  /// The rail, in order.
  List<Space> get spaces;

  /// Everything that lives in Home, before `homeSections` sorts it.
  List<Channel> get homeRooms;

  List<Invite> get invites;

  /// Asks for a room's full member list, where the backend loaded only
  /// some of it. Listeners hear when it arrives.
  void loadMembers(String roomId);

  void markRead(String roomId);
  void setMuted(String roomId, bool muted);
  void setJoined(String roomId, bool joined);
  void setFavourite(String roomId, bool favourite);

  /// Favourites in this order, first to last.
  void reorderFavourites(List<String> roomIds);
  void setLowPriority(String roomId, bool lowPriority);

  /// Throws when the server says no; the invite then stays.
  Future<void> accept(Invite invite);
  Future<void> decline(Invite invite);

  void joinSpace(Space space);

  /// Returns the new space's id.
  String createSpace(String name, {required Member me});

  /// Returns the new DM, which is already in [homeRooms].
  Channel createDirect(List<Member> members);

  void dispose();
}
