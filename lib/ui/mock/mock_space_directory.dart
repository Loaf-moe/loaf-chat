/// [SpaceDirectory] played from fixtures: [mockDirectories] and
/// [mockSpaceAddresses], answered at once.
library;

import 'package:flutter/foundation.dart';

import '../rooms/rooms.dart' show SpaceNotFound;
import '../spaces/space_address.dart';
import '../spaces/space_directory.dart';
import 'fixtures.dart';

class MockSpaceDirectory implements SpaceDirectory {
  @override
  Future<List<SpacePreview>> publicSpaces(String server) =>
      SynchronousFuture(mockDirectories[server] ?? const []);

  @override
  Future<SpacePreview> lookUp(String address) {
    final parsed = parseSpaceAddress(address);
    final entry = parsed == null ? null : mockSpaceAddresses[parsed];
    if (entry == null) return Future.error(const SpaceNotFound());
    return SynchronousFuture(entry);
  }
}
