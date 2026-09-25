/// How Home arranges the rooms that live in it. Pure, so the rules can be
/// tested apart from any widget: see "Home" in the design spec.
library;

import '../mock/fixtures.dart';

/// Home's sections, top to bottom, leaving out any that would be empty.
/// Invites come before all of these but are not rooms yet, so the list
/// draws them itself.
///
/// Each room lands in exactly one section. A favourite stays a favourite
/// even if also tagged low priority — Element can set both — and both tags
/// beat whether it is a DM.
List<ChannelCategory> homeSections(Iterable<Channel> rooms) {
  final favourites = <Channel>[];
  final direct = <Channel>[];
  final others = <Channel>[];
  final low = <Channel>[];
  for (final room in rooms) {
    if (room.favourite) {
      favourites.add(room);
    } else if (room.lowPriority) {
      low.add(room);
    } else if (room.kind == ChannelKind.direct) {
      direct.add(room);
    } else {
      others.add(room);
    }
  }

  // Your order; untagged-order favourites follow, by name.
  favourites.sort((a, b) {
    final byOrder = (a.favouriteOrder ?? double.infinity).compareTo(
      b.favouriteOrder ?? double.infinity,
    );
    return byOrder != 0 ? byOrder : _byName(a, b);
  });
  // A conversation list: whoever spoke last is on top.
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  direct.sort(
    (a, b) => (b.lastActivity ?? epoch).compareTo(a.lastActivity ?? epoch),
  );
  // Few and long-lived: a stable place beats recency.
  others.sort(_byName);
  low.sort(_byName);

  return [
    if (favourites.isNotEmpty) ChannelCategory('favourites', favourites),
    if (direct.isNotEmpty) ChannelCategory('direct messages', direct),
    if (others.isNotEmpty) ChannelCategory('rooms', others),
    if (low.isNotEmpty) ChannelCategory('low priority', low),
  ];
}

int _byName(Channel a, Channel b) =>
    a.name.toLowerCase().compareTo(b.name.toLowerCase());
