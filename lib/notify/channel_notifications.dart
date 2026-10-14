/// Desktop notifications on macOS: one method channel, whose native end is
/// `macos/Runner/NotifyBridge.swift` (UNUserNotificationCenter). Windows
/// has no channel; see `windows_notifications.dart`. The contract is in
/// this step's plan, Task 8.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart' show Logs;

import '../ui/model/chime.dart';
import '../ui/model/desktop_notifications.dart';
import '../ui/model/message_route.dart';
import '../ui/model/notice.dart';

class ChannelDesktopNotifications implements DesktopNotifications {
  ChannelDesktopNotifications({
    required this.chime,
    MethodChannel? channel,
    void Function(Object error)? log,
  }) : _channel = channel ?? const MethodChannel('moe.loaf.chat/notify'),
       _log = log ?? ((e) => Logs().w('[loaf] notification failed', e)) {
    _channel.setMethodCallHandler(_handle);
  }

  final Chime chime;
  final MethodChannel _channel;
  final void Function(Object error) _log;

  /// One line in the log, not one per message, on a platform that fails.
  var _logged = false;

  /// A click can launch the app (macOS), before Dart listens: the native
  /// side holds it until told someone is.
  late final _clicks = StreamController<MessageRoute>.broadcast(
    onListen: () => unawaited(_call<void>('ready')),
  );

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'click') return;
    if (call.arguments case {
      'roomId': final String room,
      'eventId': final String event,
    }) {
      _clicks.add(MessageRoute(room, event));
    }
  }

  void _fail(Object error) {
    if (_logged) return;
    _logged = true;
    _log(error);
  }

  Future<T?> _call<T>(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // A platform without a native end has nothing to notify with.
      return null;
    } on Object catch (e) {
      _fail(e);
      return null;
    }
  }

  @override
  Future<void> prepare() => _call<void>('prepare');

  @override
  Future<void> show(Notice notice) async {
    final sounded = await _call<bool>('show', {
      'roomId': notice.route.roomId,
      'eventId': notice.route.eventId,
      'title': notice.title,
      'body': notice.body,
      'sender': notice.sender,
      'senderId': notice.senderId,
      // Sent as null when absent: the native ends read them as optional.
      'place': notice.place,
      'avatarPath': notice.avatarPath,
      'sound': notice.sound,
    });
    // The app sounds it whenever the platform didn't, failure included.
    if (notice.sound && sounded != true) await chime.play();
  }

  @override
  Future<void> withdraw(String roomId) =>
      _call<void>('withdraw', {'roomId': roomId});

  @override
  Future<void> retract(MessageRoute route) => _call<void>('retract', {
    'roomId': route.roomId,
    'eventId': route.eventId,
  });

  @override
  Stream<MessageRoute> get clicks => _clicks.stream;

  @override
  Future<bool> blocked() async => await _call<bool>('blocked') ?? false;

  @override
  Future<void> openSystemSettings() => _call<void>('openSettings');
}
