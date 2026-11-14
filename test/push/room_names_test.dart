// The iOS extension cannot reach the running app, so it titles a push from
// what the app left in the App Group container. These pin the shape the
// extension reads, and that the file is rewritten only when it would say
// something different — a rooms change is frequent, a disk write is not free,
// and a half-written document would be read as garbage.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/push/room_names.dart';
import 'package:loaf_native/ui/mock/mock_rooms.dart';
import 'package:loaf_native/ui/model/models.dart';

Space _pack(List<Channel> channels) => Space(
  id: '!s',
  name: 'Pack',
  color: Colors.red,
  categories: [ChannelCategory('text', channels)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a DM has no place, a space channel names both', () {
    final names = roomNames(
      [
        _pack([const Channel(id: '!g', name: 'general', memberCount: 12)]),
      ],
      [
        const Channel(
          id: '!d',
          name: 'mochi',
          kind: ChannelKind.direct,
          memberCount: 2,
        ),
      ],
    );
    expect(names['!d'], {'place': null, 'dm': true, 'members': 2});
    expect(names['!g'], {
      'place': '#general · Pack',
      'dm': false,
      'members': 12,
    });
  });

  test('a channel whose count the server never sent has no members', () {
    final names = roomNames([
      _pack([const Channel(id: '!g', name: 'general')]),
    ], const []);
    expect((names['!g']! as Map)['members'], isNull);
  });

  test('a channel you are not in is left out', () {
    final names = roomNames([
      _pack([const Channel(id: '!g', name: 'general', joined: false)]),
    ], const []);
    expect(names.containsKey('!g'), isFalse);
  });

  test('rewrites only when the names would differ', () async {
    final rooms = MockRooms();
    final dir = await Directory.systemTemp.createTemp('names');
    final file = File('${dir.path}/names.json');
    final writer = RoomNamesWriter(rooms, file);
    addTearDown(() async {
      writer.dispose();
      rooms.dispose();
      await dir.delete(recursive: true);
    });

    // It writes once on creation, so the extension has names before
    // anything changes.
    expect(file.existsSync(), isTrue);
    final first = file.readAsStringSync();
    expect(jsonDecode(first), isNotEmpty);

    // Reading a room notifies, but says nothing new about names.
    file.writeAsStringSync('sentinel');
    rooms.markRead(rooms.homeRooms.first.id);
    expect(file.readAsStringSync(), 'sentinel');

    // Leaving a space takes its channels out of the document.
    await rooms.leaveSpace(rooms.spaces.first.id);
    expect(file.readAsStringSync(), isNot('sentinel'));
    expect(jsonDecode(file.readAsStringSync()), isNot(jsonDecode(first)));
  });
}
