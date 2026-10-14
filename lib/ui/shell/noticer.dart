/// Desktop notifications for the shell: what each says, and taking a
/// room's back once its messages are read, here or on another device.
/// Read is your receipt's position: on the message or later. The unread
/// count is no guide, since a message and its receipt can share a sync.
library;

import 'dart:async';

import '../model/arrival.dart';
import '../model/desktop_notifications.dart';
import '../model/message_route.dart';
import '../model/models.dart';
import '../model/notice.dart';
import '../rooms/rooms.dart';
import '../settings/notification_settings.dart';

class Noticer {
  Noticer({
    required this.desktop,
    required this.rooms,
    required this.settings,
  }) {
    rooms.addListener(_onRooms);
  }

  final DesktopNotifications desktop;
  final Rooms rooms;
  final NotificationController settings;

  /// The notices up, by room: each message's id and when it was sent.
  final _shown = <String, Map<String, DateTime?>>{};
  var _disposed = false;

  Future<void> show(Arrival a, {required bool sound}) async {
    if (!settings.notifications) return;
    // A receipt in the same sync as the message: read before it was seen.
    if (_isRead(a.roomId, a.eventId, a.sentAt)) return;
    // Recorded before the avatar is awaited, which can take seconds: a room
    // read in that window is then withdrawn like any other.
    (_shown[a.roomId] ??= {})[a.eventId] = a.sentAt;
    final ref = a.senderAvatar;
    final avatarPath = ref == null ? null : await rooms.noticeAvatar(ref);
    if (_disposed || !settings.notifications) return;
    if (!_shown.containsKey(a.roomId)) return; // Withdrawn while waiting.
    await desktop.show(
      noticeFor(
        a,
        spaces: rooms.spaces,
        homeRooms: rooms.homeRooms,
        showText: settings.showText,
        sound: sound,
        avatarPath: avatarPath,
      ),
    );
    // Read while the notice was going up: it is up now, so take it down.
    if (!_disposed && _isRead(a.roomId, a.eventId, a.sentAt)) {
      _withdraw(a.roomId);
    }
  }

  bool _isRead(String roomId, String eventId, DateTime? sentAt) =>
      _channel(roomId)?.read?.covers(eventId, sentAt) ?? false;

  Channel? _channel(String roomId) {
    for (final c in rooms.homeRooms) {
      if (c.id == roomId) return c;
    }
    for (final space in rooms.spaces) {
      for (final c in space.allChannels) {
        if (c.id == roomId && c.joined) return c;
      }
    }
    return null;
  }

  void _onRooms() {
    for (final MapEntry(key: id, value: messages) in _shown.entries.toList()) {
      final channel = _channel(id);
      if (channel == null) {
        _withdraw(id);
        continue;
      }
      final read = channel.read;
      if (read == null) continue;
      final allRead = messages.entries.every(
        (m) => read.covers(m.key, m.value),
      );
      if (allRead) _withdraw(id);
    }
  }

  /// Takes back the notice for [route]'s message: it was noticed sealed,
  /// and read says it should not have been.
  void retract(MessageRoute route) {
    final messages = _shown[route.roomId];
    if (messages != null) {
      messages.remove(route.eventId);
      if (messages.isEmpty) _shown.remove(route.roomId);
    }
    unawaited(desktop.retract(route));
  }

  void _withdraw(String roomId) {
    _shown.remove(roomId);
    unawaited(desktop.withdraw(roomId));
  }

  void dispose() {
    _disposed = true;
    rooms.removeListener(_onRooms);
  }
}
