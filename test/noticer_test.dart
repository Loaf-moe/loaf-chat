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

/// Mock rooms whose unread counts the test sets, and an avatar file for
/// anyone.
class _Rooms extends MockRooms {
  final unread = <String, int>{};

  @override
  List<Channel> get homeRooms => [
    for (final c in super.homeRooms)
      unread.containsKey(c.id) ? c.copyWith(unread: unread[c.id]) : c,
  ];

  void setUnread(String id, int n) {
    unread[id] = n;
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

  Arrival arrival(String room, {AvatarRef? avatar}) => Arrival(
    roomId: room,
    eventId: r'$e',
    senderId: '@ada:x',
    senderName: 'Ada',
    senderAvatar: avatar,
    text: 'hi',
  );

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

  test('a read room has its notices withdrawn', () async {
    rooms.setUnread(dm, 1);
    await noticer.show(arrival(dm), sound: false);
    rooms.setUnread(dm, 0);
    expect(desktop.withdrawn, [dm]);
    rooms.setUnread(dm, 0);
    expect(desktop.withdrawn, [dm], reason: 'once');
  });

  test('a notice is not withdrawn before its room was seen unread', () async {
    rooms.setUnread(dm, 0);
    await noticer.show(arrival(dm), sound: false);
    rooms.setUnread(dm, 0); // the count has not caught up yet
    expect(desktop.withdrawn, isEmpty);
    rooms.setUnread(dm, 1);
    rooms.setUnread(dm, 0);
    expect(desktop.withdrawn, [dm]);
  });

  test('a room that is gone has its notices withdrawn', () async {
    await noticer.show(arrival('!gone:x'), sound: false);
    rooms.notifyListeners();
    expect(desktop.withdrawn, ['!gone:x']);
  });

  test(
    'a room read while the avatar loads still has its notice withdrawn',
    () async {
      rooms.setUnread(dm, 1);
      rooms.avatarGate = Completer();
      final shown = noticer.show(
        arrival(dm, avatar: const AvatarRef('ada')),
        sound: false,
      );
      await pumpEventQueue();
      rooms.setUnread(dm, 0); // read on another device, notice not up yet
      rooms.avatarGate!.complete();
      await shown;
      expect(desktop.log.last, 'withdraw', reason: 'after the notice went up');
      expect(desktop.shown, hasLength(1));
    },
  );

  test('a lagging count while the avatar loads does not withdraw', () async {
    rooms.setUnread(dm, 0);
    rooms.avatarGate = Completer();
    final shown = noticer.show(
      arrival(dm, avatar: const AvatarRef('ada')),
      sound: false,
    );
    await pumpEventQueue();
    rooms.setUnread(dm, 0);
    rooms.avatarGate!.complete();
    await shown;
    expect(desktop.withdrawn, isEmpty);
  });
}
