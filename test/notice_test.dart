import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/mock_rooms.dart';
import 'package:loaf_native/ui/model/arrival.dart';
import 'package:loaf_native/ui/model/message_route.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/model/notice.dart';

void main() {
  final rooms = MockRooms();
  tearDownAll(rooms.dispose);

  Channel inSpace() => rooms.spaces.first.allChannels.firstWhere(
    (c) => c.joined && c.kind == ChannelKind.text,
  );
  Channel dm() =>
      rooms.homeRooms.firstWhere((c) => c.kind == ChannelKind.direct);

  Arrival arrival(
    String roomId, {
    String text = 'hello',
    ArrivalKind kind = ArrivalKind.text,
    String senderName = 'Ada',
  }) => Arrival(
    roomId: roomId,
    eventId: r'$e1',
    senderId: '@ada:loaf.moe',
    senderName: senderName,
    kind: kind,
    text: text,
  );

  Notice make(Arrival a, {bool showText = true}) => noticeFor(
    a,
    spaces: rooms.spaces,
    homeRooms: rooms.homeRooms,
    showText: showText,
  );

  test('a channel in a space is named with its space', () {
    final c = inSpace();
    final n = make(arrival(c.id));
    expect(n.place, '#${c.name} · ${rooms.spaces.first.name}');
    expect(n.title, 'Ada in #${c.name} · ${rooms.spaces.first.name}');
    expect(n.route, MessageRoute(c.id, r'$e1'));
  });

  test('a DM is titled with the sender alone', () {
    final n = make(arrival(dm().id));
    expect(n.place, isNull);
    expect(n.title, 'Ada');
  });

  test('an unknown room is titled with the sender alone', () {
    expect(make(arrival('!gone:x')).title, 'Ada');
  });

  test('a sender with no name is shown by id', () {
    expect(make(arrival(dm().id, senderName: '')).sender, '@ada:loaf.moe');
  });

  test('the body is the text, or what was sent', () {
    final id = dm().id;
    expect(make(arrival(id, text: '  hi there \n')).body, 'hi there');
    expect(make(arrival(id, kind: ArrivalKind.picture)).body, 'sent a picture');
    expect(make(arrival(id, kind: ArrivalKind.file)).body, 'sent a file');
    expect(
      make(arrival(id, kind: ArrivalKind.encrypted)).body,
      'encrypted message',
    );
    expect(make(arrival(id, text: '   ')).body, 'new message');
  });

  test('with message text off, the body says only that something came', () {
    final n = make(arrival(dm().id, text: 'secret'), showText: false);
    expect(n.body, 'new message');
    expect(n.title, 'Ada');
  });

  test('a long message is cut at 400 characters', () {
    final body = make(arrival(dm().id, text: 'x' * 10000)).body;
    expect(body.characters.length, noticeTextLimit + 1);
    expect(body, endsWith('…'));
  });

  test('the cut never splits a character', () {
    final body = make(arrival(dm().id, text: '👩‍👩‍👧' * 500)).body;
    expect(body.characters.length, noticeTextLimit + 1);
    expect(body.characters.first, '👩‍👩‍👧');
  });
}
