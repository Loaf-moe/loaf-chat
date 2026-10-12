/// Desktop notifications on Windows: toasts from the Rust crate in
/// `packages/loaf_notify`, called over `dart:ffi`. No method channel.
library;

import 'dart:async';

import 'package:loaf_notify/loaf_notify.dart';
import 'package:matrix/matrix.dart' show Logs;
import 'package:url_launcher/url_launcher.dart';

import '../ui/model/chime.dart';
import '../ui/model/desktop_notifications.dart';
import '../ui/model/message_route.dart';
import '../ui/model/notice.dart';

/// What [WindowsDesktopNotifications] needs of the DLL, so tests need none.
/// Statuses are the DLL's: 0 is fine, below 0 failed.
abstract interface class ToastApi {
  int register();

  int show({
    required String title,
    required String body,
    required String roomId,
    required String eventId,
    String? avatarPath,
  });

  int withdraw(String roomId);

  /// 1 when the user blocked this app's toasts, 0 when not.
  int blocked();

  /// `(roomId, eventId)` of each clicked toast.
  Stream<(String, String)> get clicks;
}

/// The real thing: [ToastNotifier], made on first use.
class NativeToastApi implements ToastApi {
  late final _notifier = ToastNotifier();

  @override
  int register() => _notifier.register();

  @override
  int show({
    required String title,
    required String body,
    required String roomId,
    required String eventId,
    String? avatarPath,
  }) => _notifier.show(
    title: title,
    body: body,
    roomId: roomId,
    eventId: eventId,
    avatarPath: avatarPath,
  );

  @override
  int withdraw(String roomId) => _notifier.withdraw(roomId);

  @override
  int blocked() => _notifier.blocked();

  @override
  Stream<(String, String)> get clicks => _notifier.clicks;
}

class WindowsDesktopNotifications implements DesktopNotifications {
  WindowsDesktopNotifications({
    required this.chime,
    ToastApi? toasts,
    Future<bool> Function(Uri uri)? launch,
    void Function(Object error)? log,
  }) : _toasts = toasts ?? NativeToastApi(),
       _launch = launch ?? launchUrl,
       _log = log ?? ((e) => Logs().w('[loaf] notification failed', e));

  final Chime chime;
  final ToastApi _toasts;
  final Future<bool> Function(Uri uri) _launch;
  final void Function(Object error) _log;

  /// One line in the log, not one per message, on a machine that fails.
  var _logged = false;

  void _fail(Object error) {
    if (_logged) return;
    _logged = true;
    _log(error);
  }

  /// Runs [call], logging a failure status or a throw (no DLL) once.
  int _status(String what, int Function() call) {
    try {
      final status = call();
      if (status < 0) _fail('$what failed: status $status');
      return status;
    } on Object catch (e) {
      _fail(e);
      return -1;
    }
  }

  @override
  Future<void> prepare() async {
    _status('register', _toasts.register);
  }

  @override
  Future<void> show(Notice notice) async {
    _status(
      'show',
      () => _toasts.show(
        title: notice.title,
        body: notice.body,
        roomId: notice.route.roomId,
        eventId: notice.route.eventId,
        avatarPath: notice.avatarPath,
      ),
    );
    // A toast can't carry the app's chime on Windows, so the app plays it,
    // whether or not the toast showed.
    if (notice.sound) await chime.play();
  }

  @override
  Future<void> withdraw(String roomId) async {
    _status('withdraw', () => _toasts.withdraw(roomId));
  }

  @override
  Stream<MessageRoute> get clicks {
    try {
      return _toasts.clicks.map((c) => MessageRoute(c.$1, c.$2));
    } on Object catch (e) {
      _fail(e);
      return const Stream.empty();
    }
  }

  @override
  Future<bool> blocked() async => _status('blocked', _toasts.blocked) == 1;

  @override
  Future<void> openSystemSettings() async {
    try {
      if (!await _launch(Uri.parse('ms-settings:notifications'))) {
        _fail('could not open ms-settings:notifications');
      }
    } on Object catch (e) {
      _fail(e);
    }
  }
}
