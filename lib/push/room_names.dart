/// The room names the iOS Notification Service Extension titles a push with.
/// The extension cannot reach the running app, so the app leaves them in the
/// App Group container for it to read.
library;

import 'dart:convert';
import 'dart:io';

import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/model/notice.dart';
import 'package:loaf_native/ui/rooms/rooms.dart';

/// `{roomId: {"place": String?, "dm": bool, "members": int?}}` over every
/// channel you are in, so the extension titles a notification exactly as
/// the app titles its own — [noticePlace] is the one source for both.
Map<String, Object> roomNames(List<Space> spaces, List<Channel> homeRooms) {
  final names = <String, Object>{};
  void add(Channel channel) {
    if (!channel.joined) return;
    names[channel.id] = {
      'place': noticePlace(channel.id, spaces: spaces, homeRooms: homeRooms),
      'dm': channel.kind == ChannelKind.direct,
      'members': channel.memberCount,
    };
  }

  for (final channel in homeRooms) {
    add(channel);
  }
  for (final space in spaces) {
    for (final channel in space.allChannels) {
      add(channel);
    }
  }
  return names;
}

/// Keeps `names.json` level with the rooms. It writes once when made, so
/// the extension has names before anything changes, and after that only
/// when the document would differ: rooms notify far more often than a
/// name moves.
class RoomNamesWriter {
  RoomNamesWriter(this.rooms, this.file) {
    rooms.addListener(_write);
    _write();
  }

  final Rooms rooms;
  final File file;
  String? _written;

  void dispose() => rooms.removeListener(_write);

  void _write() {
    final json = jsonEncode(roomNames(rooms.spaces, rooms.homeRooms));
    if (json == _written) return;
    // Beside, then rename: the extension may read at any moment, and a
    // rename is the one way it never sees half a document. Synchronous
    // because a rooms change is not a frame, the document is small, and
    // the skip above means most changes write nothing at all.
    File('${file.path}.tmp')
      ..writeAsStringSync(json)
      ..renameSync(file.path);
    _written = json;
  }
}
