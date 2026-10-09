/// Desktop notifications for the shell: what each says, and taking a
/// room's back once it is read, here or on another device.
library;

import 'dart:async';

import '../model/arrival.dart';
import '../model/desktop_notifications.dart';
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

  /// Rooms with notices up, and whether each has been seen unread since.
  /// A count can lag its message within a sync: a room read as 0 before it
  /// was ever seen unread has not been read, only not yet counted.
  final _shown = <String, bool>{};
  var _disposed = false;

  Future<void> show(Arrival a, {required bool sound}) async {
    if (!settings.notifications) return;
    final ref = a.senderAvatar;
    final avatarPath = ref == null ? null : await rooms.noticeAvatar(ref);
    if (_disposed || !settings.notifications) return;
    _shown[a.roomId] = (_shown[a.roomId] ?? false) || _unread(a.roomId);
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
  }

  bool _unread(String roomId) {
    final c = _channel(roomId);
    return c != null && (c.unread > 0 || c.mentions > 0);
  }

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
    for (final MapEntry(key: id, value: seen) in _shown.entries.toList()) {
      if (_channel(id) == null) {
        _withdraw(id);
      } else if (_unread(id)) {
        _shown[id] = true;
      } else if (seen) {
        _withdraw(id);
      }
    }
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
