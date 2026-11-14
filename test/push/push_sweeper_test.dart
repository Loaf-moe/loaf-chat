// Reading a room on another device has to take its notifications off this
// one. The sweep is bounded by `settledBefore` — the moment everything the
// counts know about was already sent — so a notice that arrived after the
// server counted is never swept away unread.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/push/push_sweeper.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/rooms/rooms.dart';

typedef _Withdrawn = ({String roomId, DateTime? before});

class _FakeRooms extends ChangeNotifier implements Rooms {
  @override
  DateTime? settledBefore;

  @override
  List<Channel> homeRooms = const [];

  @override
  List<Space> spaces = const [];

  void change({DateTime? settled, List<Channel>? rooms, List<Space>? places}) {
    if (settled != null) settledBefore = settled;
    if (rooms != null) homeRooms = rooms;
    if (places != null) spaces = places;
    notifyListeners();
  }

  // The sweeper reads three members; anything else is a test bug, not a
  // silent default.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Channel _room(
  String id, {
  int unread = 0,
  int mentions = 0,
  bool joined = true,
}) => Channel(
  id: id,
  name: id,
  unread: unread,
  mentions: mentions,
  joined: joined,
);

void main() {
  late List<_Withdrawn> withdrawn;
  final t1 = DateTime.utc(2026, 11, 14, 9);
  final t2 = DateTime.utc(2026, 11, 14, 9, 1);

  PushSweeper sweep(Rooms rooms) {
    final sweeper = PushSweeper(
      rooms: rooms,
      withdraw: (roomId, {before}) async =>
          withdrawn.add((roomId: roomId, before: before)),
    );
    addTearDown(sweeper.dispose);
    return sweeper;
  }

  setUp(() => withdrawn = []);

  test('nothing is taken back until two syncs have landed', () {
    final rooms = _FakeRooms()..homeRooms = [_room('!r')];
    sweep(rooms);
    rooms.change(rooms: [_room('!r')]);
    expect(withdrawn, isEmpty);
  });

  test('a room with nothing unread has its notifications taken back', () {
    final rooms = _FakeRooms()..homeRooms = [_room('!r')];
    sweep(rooms);
    rooms.change(settled: t1);
    expect(withdrawn, [(roomId: '!r', before: t1)]);
  });

  test('the same moment does not sweep twice', () {
    final rooms = _FakeRooms()..homeRooms = [_room('!r')];
    sweep(rooms);
    rooms.change(settled: t1);
    rooms.change(rooms: [_room('!r')]);
    expect(withdrawn, hasLength(1));
  });

  test('a later moment sweeps again, for what arrived since', () {
    final rooms = _FakeRooms()..homeRooms = [_room('!r')];
    sweep(rooms);
    rooms.change(settled: t1);
    rooms.change(settled: t2);
    expect(withdrawn, [(roomId: '!r', before: t1), (roomId: '!r', before: t2)]);
  });

  test('a room still unread keeps its notifications', () {
    final rooms = _FakeRooms()..homeRooms = [_room('!r', unread: 1)];
    sweep(rooms);
    rooms.change(settled: t1);
    expect(withdrawn, isEmpty);
  });

  test('a room with a mention keeps them even at zero unread', () {
    final rooms = _FakeRooms()..homeRooms = [_room('!r', mentions: 1)];
    sweep(rooms);
    rooms.change(settled: t1);
    expect(withdrawn, isEmpty);
  });

  test('a space channel is swept like any other room', () {
    final rooms = _FakeRooms()
      ..spaces = [
        Space(
          id: '!s',
          name: 'Pack',
          color: const Color(0xFF000000),
          categories: [
            ChannelCategory('text', [_room('!g'), _room('!u', unread: 2)]),
          ],
        ),
      ];
    sweep(rooms);
    rooms.change(settled: t1);
    expect(withdrawn, [(roomId: '!g', before: t1)]);
  });

  test('a channel you are not in is left alone', () {
    final rooms = _FakeRooms()..homeRooms = [_room('!r', joined: false)];
    sweep(rooms);
    rooms.change(settled: t1);
    expect(withdrawn, isEmpty);
  });
}
