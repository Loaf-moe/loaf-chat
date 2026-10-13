import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_rooms.dart';
import 'package:loaf_native/ui/model/arrival.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/model/desktop_notifications.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/model/notice.dart';
import 'package:loaf_native/ui/settings/notification_settings.dart';
import 'package:loaf_native/ui/shell/noticer.dart';

/// Mock rooms whose read receipts the test sets, and an avatar file for
/// anyone.
class _Rooms extends MockRooms {
  final marks = <String, ReadMark>{};

  @override
  List<Channel> get homeRooms => [
    for (final c in super.homeRooms)
      marks.containsKey(c.id) ? c.copyWith(read: marks[c.id]) : c,
  ];

  void setRead(String id, ReadMark mark) {
    marks[id] = mark;
    notifyListeners();
  }

  /// When set, the avatar waits on it: the window a read can land in.
  Completer<void>? avatarGate;

  @override
  Future<String?> noticeAvatar(AvatarRef ref) async {
    await avatarGate?.future;
    return '/tmp/${ref.value}.png';
  }
}

/// Notes the order of shows and withdrawals.
class _Desktop extends FakeDesktopNotifications {
  final log = <String>[];

  @override
  Future<void> show(Notice notice) async {
    await super.show(notice);
    log.add('show');
  }

  @override
  Future<void> withdraw(String roomId) async {
    await super.withdraw(roomId);
    log.add('withdraw');
  }
}

void main() {
  late _Rooms rooms;
  late _Desktop desktop;
  late NotificationController settings;
  late Noticer noticer;
  late String dm;

  setUp(() async {
    rooms = _Rooms();
    desktop = _Desktop();
    settings = await NotificationController.load(
      MemoryNotificationStore(),
      chime: FakeChime(),
      desktop: desktop,
    );
    noticer = Noticer(desktop: desktop, rooms: rooms, settings: settings);
    dm = rooms.homeRooms.firstWhere((c) => c.kind == ChannelKind.direct).id;
  });

  tearDown(() {
    noticer.dispose();
    rooms.dispose();
  });

  final sent = DateTime.utc(2026, 10, 14, 12);

  Arrival arrival(String room, {AvatarRef? avatar, String id = r'$e'}) =>
      Arrival(
        roomId: room,
        eventId: id,
        senderId: '@ada:x',
        senderName: 'Ada',
        senderAvatar: avatar,
        text: 'hi',
        sentAt: sent,
      );

  /// Your receipt [seconds] after [sent], on no event in particular.
  ReadMark readAt(int seconds) =>
      ReadMark(at: sent.add(Duration(seconds: seconds)));

  test(
    'shows a notice with the avatar file and the sound it was given',
    () async {
      await noticer.show(
        arrival(dm, avatar: const AvatarRef('ada')),
        sound: true,
      );
      expect(desktop.shown.single.title, 'Ada');
      expect(desktop.shown.single.body, 'hi');
      expect(desktop.shown.single.avatarPath, '/tmp/ada.png');
      expect(desktop.shown.single.sound, isTrue);
    },
  );

  test('with notifications off, shows nothing', () async {
    settings.setNotifications(false);
    await noticer.show(arrival(dm), sound: true);
    expect(desktop.shown, isEmpty);
  });

  test('with message text off, the body hides it', () async {
    settings.setShowText(false);
    await noticer.show(arrival(dm), sound: false);
    expect(desktop.shown.single.body, 'new message');
  });

  test('a notice is withdrawn once your receipt covers its message', () async {
    await noticer.show(arrival(dm), sound: false);
    rooms.setRead(dm, readAt(1));
    expect(desktop.withdrawn, [dm]);
    rooms.setRead(dm, readAt(2));
    expect(desktop.withdrawn, [dm], reason: 'once');
  });

  test('a receipt on the message itself covers it', () async {
    await noticer.show(arrival(dm), sound: false);
    rooms.setRead(
      dm,
      ReadMark(eventId: r'$e', at: sent.subtract(const Duration(days: 1))),
    );
    expect(desktop.withdrawn, [dm]);
  });

  test('a receipt short of the message keeps the notice', () async {
    await noticer.show(arrival(dm), sound: false);
    rooms.setRead(dm, readAt(-1));
    expect(desktop.withdrawn, isEmpty);
  });

  test('a message already read when it arrives leaves no notice', () async {
    rooms.setRead(dm, readAt(1));
    await noticer.show(arrival(dm), sound: false);
    expect(desktop.shown, isEmpty);
    expect(desktop.withdrawn, isEmpty);
  });

  test('two messages, a receipt short of the newest: both stay', () async {
    await noticer.show(arrival(dm, id: r'$a'), sound: false);
    await noticer.show(
      Arrival(
        roomId: dm,
        eventId: r'$b',
        senderId: '@ada:x',
        senderName: 'Ada',
        text: 'hi',
        sentAt: sent.add(const Duration(minutes: 5)),
      ),
      sound: false,
    );
    rooms.setRead(dm, readAt(60));
    expect(desktop.withdrawn, isEmpty);
    rooms.setRead(dm, readAt(600));
    expect(desktop.withdrawn, [dm]);
  });

  test('a room that is gone has its notices withdrawn', () async {
    await noticer.show(arrival('!gone:x'), sound: false);
    rooms.notifyListeners();
    expect(desktop.withdrawn, ['!gone:x']);
  });

  test('a room read while the avatar loads shows no notice', () async {
    rooms.avatarGate = Completer();
    final shown = noticer.show(
      arrival(dm, avatar: const AvatarRef('ada')),
      sound: false,
    );
    await pumpEventQueue();
    rooms.setRead(dm, readAt(1)); // read on another device, notice not up yet
    rooms.avatarGate!.complete();
    await shown;
    expect(desktop.shown, isEmpty);
  });
}
