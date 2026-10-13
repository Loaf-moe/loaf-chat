/// What a desktop notification says about one message, and where clicking
/// it leads. Built from an [Arrival] and the rooms as the shell knows them.
library;

import 'package:flutter/widgets.dart';

import 'arrival.dart';
import 'message_route.dart';
import 'models.dart';

/// Past this many characters a message is cut: platforms truncate long
/// text anyway, and a Windows toast over 5 KB is silently dropped.
const noticeTextLimit = 400;

@immutable
class Notice {
  const Notice({
    required this.route,
    required this.sender,
    required this.senderId,
    required this.body,
    this.place,
    this.avatarPath,
    this.sound = false,
  });

  final MessageRoute route;
  final String sender;
  final String senderId;

  /// `#general · The Starter Pack`; `#general` for a room in Home; null in
  /// a DM, where the sender is the conversation.
  final String? place;
  final String body;

  /// The sender's picture on disk, where there is one.
  final String? avatarPath;

  /// Whether the chime goes with it.
  final bool sound;

  String get title => place == null ? sender : '$sender in $place';
}

/// Where [roomId] is, for a notification's title. The first space on the
/// rail that has it joined, as the jump to it would choose.
String? noticePlace(
  String roomId, {
  required List<Space> spaces,
  required List<Channel> homeRooms,
}) {
  final home = homeRooms.where((c) => c.id == roomId).firstOrNull;
  if (home?.kind == ChannelKind.direct) return null;
  for (final space in spaces) {
    for (final c in space.allChannels) {
      if (c.id == roomId && c.joined) return '#${c.name} · ${space.name}';
    }
  }
  return home == null ? null : '#${home.name}';
}

String noticeBody(Arrival a, {required bool showText}) {
  if (!showText) return 'new message';
  return switch (a.kind) {
    ArrivalKind.picture => 'sent a picture',
    ArrivalKind.file => 'sent a file',
    ArrivalKind.encrypted => 'encrypted message',
    ArrivalKind.text => _clip(a.text.trim()),
  };
}

// Cut by grapheme, so an emoji or a combining mark is never split.
String _clip(String text) {
  if (text.isEmpty) return 'new message';
  final chars = text.characters;
  if (chars.length <= noticeTextLimit) return text;
  return '${chars.take(noticeTextLimit)}…';
}

Notice noticeFor(
  Arrival a, {
  required List<Space> spaces,
  required List<Channel> homeRooms,
  required bool showText,
  bool sound = false,
  String? avatarPath,
}) => Notice(
  route: MessageRoute(a.roomId, a.eventId),
  sender: a.senderName.isEmpty ? a.senderId : a.senderName,
  senderId: a.senderId,
  place: noticePlace(a.roomId, spaces: spaces, homeRooms: homeRooms),
  body: noticeBody(a, showText: showText),
  avatarPath: avatarPath,
  sound: sound,
);
