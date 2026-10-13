/// The desktop's own notifications: Notification Center, toasts, the
/// freedesktop server or portal. One per app run, so a click that launched
/// the app is not lost. See `lib/notify/` for the implementations.
library;

import 'dart:async';

import 'message_route.dart';
import 'notice.dart';

/// None of these throws: a notification that can't be shown isn't worth
/// an error in front of you. Failures are logged once.
abstract interface class DesktopNotifications {
  /// Gets ready to show: on macOS asks permission if it was never asked; on
  /// Windows registers the app's name and icon. Called when the shell opens.
  Future<void> prepare();

  /// Shows [notice], sounding the chime with it when [Notice.sound] says
  /// so, through the platform where it can and the app where it can't.
  Future<void> show(Notice notice);

  /// Takes back every notification shown for [roomId].
  Future<void> withdraw(String roomId);

  /// Takes back the one notification shown for [route]'s message, if up.
  Future<void> retract(MessageRoute route);

  /// Where clicked notifications lead.
  Stream<MessageRoute> get clicks;

  /// Whether the OS has been told to block this app's notifications. Always
  /// false where that can't be read (Linux).
  Future<bool> blocked();

  /// Opens the OS's notification settings for this app.
  Future<void> openSystemSettings();
}

/// Records calls: for tests only.
class FakeDesktopNotifications implements DesktopNotifications {
  final shown = <Notice>[];
  final withdrawn = <String>[];
  final retracted = <MessageRoute>[];
  var prepared = 0;
  var isBlocked = false;
  var settingsOpened = 0;
  final _clicks = StreamController<MessageRoute>.broadcast();

  void click(MessageRoute route) => _clicks.add(route);

  @override
  Future<void> prepare() async => prepared++;

  @override
  Future<void> show(Notice notice) async => shown.add(notice);

  @override
  Future<void> withdraw(String roomId) async => withdrawn.add(roomId);

  @override
  Future<void> retract(MessageRoute route) async => retracted.add(route);

  @override
  Stream<MessageRoute> get clicks => _clicks.stream;

  @override
  Future<bool> blocked() async => isBlocked;

  @override
  Future<void> openSystemSettings() async => settingsOpened++;
}
