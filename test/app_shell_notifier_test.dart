import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/mock/mock_rooms.dart';
import 'package:loaf_native/ui/model/arrival.dart';
import 'package:loaf_native/ui/model/chime.dart';
import 'package:loaf_native/ui/settings/notification_settings.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/shell/spaces_rail.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

/// The mock rooms, with arrivals the test sends itself.
class _Rooms extends MockRooms {
  final controller = StreamController<Arrival>.broadcast();

  @override
  Stream<Arrival> get arrivals => controller.stream;

  @override
  void dispose() {
    unawaited(controller.close());
    super.dispose();
  }
}

void main() {
  late _Rooms rooms;
  late FakeChime chime;
  late NotificationController notifications;
  var n = 0;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    rooms = _Rooms();
    chime = FakeChime();
    notifications = await NotificationController.load(
      MemoryNotificationStore(),
      chime: chime,
    );
    await tester.pumpWidget(
      NotificationScope(
        controller: notifications,
        child: MaterialApp(
          theme: loafLightTheme(),
          home: AppShell(rooms: () => rooms),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> arrive(WidgetTester tester, String room) async {
    rooms.controller.add(Arrival(roomId: room, eventId: '\$${n++}'));
    await tester.pump();
  }

  // The channel the shell opens on, and another one.
  String openId() => rooms.spaces.first.allChannels
      .firstWhere((c) => c.kind != ChannelKind.voice && c.joined)
      .id;

  testWidgets('chimes for another channel, not for the open one', (
    tester,
  ) async {
    await pump(tester);
    await arrive(tester, openId());
    expect(chime.plays, 0);
    await arrive(tester, 'somewhere-else');
    expect(chime.plays, 1);
  });

  testWidgets('with sound off, nothing plays', (tester) async {
    await pump(tester);
    notifications.setSound(false);
    await arrive(tester, 'somewhere-else');
    await tester.binding.delayed(const Duration(seconds: 1));
    await arrive(tester, 'somewhere-else');
    expect(chime.plays, 0);
  });

  testWidgets('an invite preview has no channel on screen, so it chimes', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(SpacesRail.homeKey));
    await tester.pumpAndSettle();
    // Home's own channel is open until the invite takes its place.
    final id = rooms.homeRooms
        .firstWhere((c) => c.kind != ChannelKind.voice && c.joined)
        .id;
    await arrive(tester, id);
    expect(chime.plays, 0, reason: 'open before the preview');
    await tester.binding.delayed(const Duration(seconds: 1));
    final invite = mockInvites.first;
    await tester.tap(find.text(invite.name).first);
    await tester.pumpAndSettle();
    await arrive(tester, id);
    expect(chime.plays, 1);
  });
}
