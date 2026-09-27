import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/mock/mock_rooms.dart';
import 'package:loaf_native/ui/rooms/rooms.dart';

Channel _home(MockRooms rooms, String id) =>
    rooms.homeRooms.firstWhere((c) => c.id == id);

Channel _channel(MockRooms rooms, String id) =>
    rooms.spaces.expand((s) => s.allChannels).firstWhere((c) => c.id == id);

void main() {
  late MockRooms rooms;
  var heard = 0;

  setUp(() {
    rooms = MockRooms();
    heard = 0;
    rooms.addListener(() => heard++);
  });
  tearDown(() => rooms.dispose());

  test('can do everything, and is synced from the start', () {
    expect(rooms.abilities, RoomAbility.values.toSet());
    expect(rooms.synced, isTrue);
    expect(rooms.syncProgress, isNull);
    expect(rooms.me, currentUser);
  });

  test('marking read clears a room\'s counts, once', () {
    expect(_home(rooms, 'fermentation').unread, greaterThan(0));
    rooms
      ..markRead('fermentation')
      ..markRead('fermentation');
    expect(_home(rooms, 'fermentation').unread, 0);
    expect(heard, 1);
  });

  test('marking a space channel read recounts the space', () {
    final space = rooms.spaces.first;
    final unread = space.allChannels.firstWhere((c) => c.unread > 0);
    rooms.markRead(unread.id);
    expect(_channel(rooms, unread.id).unread, 0);
    expect(_channel(rooms, unread.id).mentions, 0);
  });

  test('a left Home room is gone; a left channel stays, to rejoin', () {
    final channel = rooms.spaces.first.allChannels.firstWhere(
      (c) => !c.private,
    );
    rooms
      ..setJoined('admins', false)
      ..setJoined(channel.id, false);
    expect(rooms.homeRooms.map((c) => c.id), isNot(contains('admins')));
    expect(_channel(rooms, channel.id).joined, isFalse);
  });

  test('a new favourite goes last, and reordering is kept', () {
    rooms.setFavourite('admins', true);
    final favourites = rooms.homeRooms.where((c) => c.favourite).toList()
      ..sort((a, b) => a.favouriteOrder!.compareTo(b.favouriteOrder!));
    expect(favourites.last.id, 'admins');
    rooms.reorderFavourites(['admins', 'dm-mika']);
    expect(_home(rooms, 'admins').favouriteOrder, 0);
  });

  test('muting and low priority reach Home rooms', () {
    rooms
      ..setMuted('admins', true)
      ..setLowPriority('admins', true);
    expect(_home(rooms, 'admins').muted, isTrue);
    expect(_home(rooms, 'admins').lowPriority, isTrue);
  });

  test('accepting a DM invite brings it into Home at once', () {
    final invite = rooms.invites.firstWhere((i) => i.room != null);
    var done = false;
    rooms.accept(invite).then((_) => done = true);
    // A SynchronousFuture: the shell carries on in the same frame.
    expect(done, isTrue);
    expect(rooms.invites, isNot(contains(invite)));
    expect(rooms.homeRooms.map((c) => c.id), contains(invite.room!.id));
  });

  test('joining a space you were invited to answers the invite', () {
    final invite = rooms.invites.firstWhere((i) => i.space != null);
    rooms.joinSpace(invite.space!);
    expect(rooms.invites, isNot(contains(invite)));
    expect(rooms.spaces.map((s) => s.id), contains(invite.space!.id));
  });

  test('a made space has #general and a voice channel', () {
    final id = rooms.createSpace('Crumb Club', me: currentUser);
    final space = rooms.spaces.firstWhere((s) => s.id == id);
    expect(space.allChannels.map((c) => c.name), ['general', 'hangout']);
  });

  test('a started DM is in Home, waiting on its people', () {
    final ada = rooms.homeRooms
        .firstWhere((c) => c.id == 'dm-ada')
        .members
        .single;
    final dm = rooms.createDirect([ada]);
    expect(_home(rooms, dm.id).waitingFor, [ada]);
  });
}
