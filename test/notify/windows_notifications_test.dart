import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/notify/windows_notifications.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/model/message_route.dart';
import 'package:loaf_native/ui/model/notice.dart';

/// Stands in for the Rust DLL: records calls, answers with set statuses.
class _FakeToasts implements ToastApi {
  var registerStatus = 0;
  var showStatus = 0;
  var blockedStatus = 0;
  var registered = 0;
  final shown = <Map<String, String?>>[];
  final withdrawn = <String>[];
  final _clicks = StreamController<(String, String)>.broadcast();

  void click(String room, String event) => _clicks.add((room, event));

  @override
  int register() {
    registered++;
    return registerStatus;
  }

  @override
  int show({
    required String title,
    required String body,
    required String roomId,
    required String eventId,
    String? avatarPath,
  }) {
    shown.add({
      'title': title,
      'body': body,
      'roomId': roomId,
      'eventId': eventId,
      'avatarPath': avatarPath,
    });
    return showStatus;
  }

  @override
  int withdraw(String roomId) {
    withdrawn.add(roomId);
    return 0;
  }

  @override
  int blocked() => blockedStatus;

  @override
  Stream<(String, String)> get clicks => _clicks.stream;
}

Notice _notice({bool sound = true, String? avatar}) => Notice(
  route: const MessageRoute('!r:x', r'$e'),
  sender: 'Ada',
  senderId: '@ada:x',
  place: '#general · Loaf',
  body: 'hi',
  sound: sound,
  avatarPath: avatar,
);

void main() {
  late _FakeToasts toasts;
  late FakeChime chime;
  late List<Object> logged;
  late List<Uri> launched;

  WindowsDesktopNotifications make() => WindowsDesktopNotifications(
    chime: chime,
    toasts: toasts,
    log: logged.add,
    launch: (uri) async {
      launched.add(uri);
      return true;
    },
  );

  setUp(() {
    toasts = _FakeToasts();
    chime = FakeChime();
    logged = [];
    launched = [];
  });

  test('show sends the fields and chimes itself', () async {
    await make().show(_notice(avatar: r'C:\a.png'));
    expect(toasts.shown, [
      {
        'title': 'Ada in #general · Loaf',
        'body': 'hi',
        'roomId': '!r:x',
        'eventId': r'$e',
        'avatarPath': r'C:\a.png',
      },
    ]);
    expect(chime.plays, 1);
  });

  test('a silent notice does not chime', () async {
    await make().show(_notice(sound: false));
    expect(toasts.shown, hasLength(1));
    expect(chime.plays, 0);
  });

  test('a failing show still chimes and logs once', () async {
    toasts.showStatus = -3;
    final n = make();
    await n.show(_notice());
    await n.show(_notice());
    expect(chime.plays, 2);
    expect(logged, hasLength(1));
  });

  test('a throwing api is swallowed, then chimes', () async {
    final n = WindowsDesktopNotifications(
      chime: chime,
      toasts: _Throwing(),
      log: logged.add,
      launch: (_) async => true,
    );
    await n.show(_notice());
    await n.prepare();
    expect(await n.blocked(), isFalse);
    expect(chime.plays, 1);
    expect(logged, hasLength(1));
  });

  test('prepare registers; a failure is logged, not thrown', () async {
    final n = make();
    await n.prepare();
    expect(toasts.registered, 1);
    expect(logged, isEmpty);
    toasts.registerStatus = -3;
    await n.prepare();
    expect(logged, hasLength(1));
  });

  test('blocked is true only on status 1', () async {
    final n = make();
    expect(await n.blocked(), isFalse);
    toasts.blockedStatus = 1;
    expect(await n.blocked(), isTrue);
    toasts.blockedStatus = -3;
    expect(await n.blocked(), isFalse);
  });

  test('withdraw goes to the api', () async {
    await make().withdraw('!r:x');
    expect(toasts.withdrawn, ['!r:x']);
  });

  test('retract takes back the room\'s toasts', () async {
    await make().retract(const MessageRoute('!r:x', r'$e'));
    expect(toasts.withdrawn, ['!r:x']);
  });

  test('a click becomes a route', () async {
    final routes = <MessageRoute>[];
    final sub = make().clicks.listen(routes.add);
    toasts.click('!r:x', r'$e');
    await pumpEventQueue();
    expect(routes, [const MessageRoute('!r:x', r'$e')]);
    await sub.cancel();
  });

  test('a launcher that returns false is logged once', () async {
    final n = WindowsDesktopNotifications(
      chime: chime,
      toasts: toasts,
      log: logged.add,
      launch: (_) async => false,
    );
    await n.openSystemSettings();
    await n.openSystemSettings();
    expect(logged, hasLength(1));
  });

  test('openSystemSettings launches ms-settings', () async {
    await make().openSystemSettings();
    expect(launched, [Uri.parse('ms-settings:notifications')]);
  });
}

class _Throwing implements ToastApi {
  @override
  int register() => throw StateError('no dll');
  @override
  int show({
    required String title,
    required String body,
    required String roomId,
    required String eventId,
    String? avatarPath,
  }) => throw StateError('no dll');
  @override
  int withdraw(String roomId) => throw StateError('no dll');
  @override
  int blocked() => throw StateError('no dll');
  @override
  Stream<(String, String)> get clicks => const Stream.empty();
}
