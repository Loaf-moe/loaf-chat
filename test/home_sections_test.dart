import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/home/home_sections.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/shell/channel_actions.dart';

const _ana = Member('@ana', 'Ana', Colors.blue);

Channel _dm(String id, {int daysAgo = 0}) => Channel(
  id: id,
  name: id,
  kind: ChannelKind.direct,
  members: const [_ana],
  lastActivity: DateTime(2026, 9, 24 - daysAgo),
);

Channel _room(String id) => Channel(id: id, name: id, kind: ChannelKind.room);

List<String> _names(ChannelCategory c) => [for (final r in c.channels) r.id];

void main() {
  group('homeSections', () {
    test('runs favourites, DMs, rooms, low priority, skipping empty ones', () {
      final sections = homeSections([
        _room('zeta').copyWith(lowPriority: true),
        _dm('ana'),
        _room('admins'),
      ]);

      expect(
        [for (final s in sections) s.name],
        ['direct messages', 'rooms', 'low priority'],
      );
    });

    test('each room appears once: favourite beats low priority beats the '
        'rest', () {
      final sections = homeSections([
        _room('both').copyWith(favourite: true, lowPriority: true),
        _dm('ana').copyWith(lowPriority: true),
      ]);

      expect(sections.map((s) => s.name), ['favourites', 'low priority']);
      expect(_names(sections.first), ['both']);
      expect(_names(sections.last), ['ana']);
    });

    test('favourites keep your order', () {
      final sections = homeSections([
        _room('b').copyWith(favourite: true, favouriteOrder: 0.2),
        _room('a').copyWith(favourite: true, favouriteOrder: 0.7),
        _dm('c').copyWith(favourite: true, favouriteOrder: 0.1),
      ]);

      expect(_names(sections.single), ['c', 'b', 'a']);
    });

    test('DMs put the most recent conversation first', () {
      final sections = homeSections([
        _dm('old', daysAgo: 5),
        _dm('new'),
        _dm('mid', daysAgo: 2),
      ]);

      expect(_names(sections.single), ['new', 'mid', 'old']);
    });

    test('rooms and low priority stay alphabetical', () {
      final sections = homeSections([
        _room('Zest'),
        _room('admins'),
        _room('Bakers'),
      ]);

      expect(_names(sections.single), ['admins', 'Bakers', 'Zest']);
    });
  });

  group('actions on Home rows', () {
    test('a Home room can be favourited or sent to low priority', () {
      final actions = actionsFor(_room('admins'), home: true);

      expect(actions, contains(ChannelAction.favourite));
      expect(actions, contains(ChannelAction.lowPriority));
    });

    test('a favourite offers the way back out', () {
      final actions = actionsFor(
        _room('admins').copyWith(favourite: true, lowPriority: true),
        home: true,
      );

      expect(actions, contains(ChannelAction.unfavourite));
      expect(actions, contains(ChannelAction.notLowPriority));
    });

    test('space channels are never tagged from loaf', () {
      final actions = actionsFor(const Channel(id: 'general', name: 'general'));

      expect(actions, isNot(contains(ChannelAction.favourite)));
      expect(actions, isNot(contains(ChannelAction.lowPriority)));
    });
  });
}
