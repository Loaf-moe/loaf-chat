/// The iOS end of `moe.loaf.chat/notify`, whose native side is
/// `ios/Runner/NotifyBridge.swift`. It shares the channel and most of the
/// methods with the macOS desktop notifications, because the two do the same
/// things to the same `UNUserNotificationCenter`; what is only iOS's is
/// [pushToken], and a [withdraw] that can take back part of a room.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart' show Logs;

import '../ui/model/desktop_notifications.dart';
import '../ui/model/message_route.dart';

class IosPush implements NotificationPermissions {
  IosPush({MethodChannel? channel, void Function(Object error)? log})
    : _channel = channel ?? const MethodChannel('moe.loaf.chat/notify'),
      _log = log ?? ((e) => Logs().w('[loaf] push', e)) {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  final void Function(Object error) _log;

  /// One line in the log, not one per message, on a platform that fails.
  var _logged = false;

  /// A tap can launch the app before Dart listens: the native side holds it
  /// until told someone is.
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
      // A platform without a native end has nothing to push with.
      return null;
    } on Object catch (e) {
      _fail(e);
      return null;
    }
  }

  Stream<MessageRoute> get clicks => _clicks.stream;

  @override
  Future<void> prepare() => _call<void>('prepare');

  /// The APNs token as hex, or null: no permission, no network, or the 20 s
  /// the native side waits ran out. Registering is the native side's to do.
  Future<String?> pushToken() => _call<String>('pushToken');

  /// Takes back this room's notifications. [before] takes back only what
  /// arrived before it, so reading up to a point leaves the rest standing.
  Future<void> withdraw(String roomId, {DateTime? before}) => _call<void>(
    'withdraw',
    {'roomId': roomId, 'before': before?.millisecondsSinceEpoch},
  );

  @override
  Future<bool> blocked() async => await _call<bool>('blocked') ?? false;

  @override
  Future<void> openSystemSettings() => _call<void>('openSettings');
}
