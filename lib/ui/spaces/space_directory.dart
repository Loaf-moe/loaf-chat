/// Finding spaces you have not joined yet, whether by browsing a server's
/// public directory or by resolving an address someone shared.
library;

import '../model/models.dart';
import '../rooms/rooms.dart' show SpaceNotFound;

abstract interface class SpaceDirectory {
  /// A server's public spaces (`/publicRooms`, filtered to spaces).
  Future<List<SpacePreview>> publicSpaces(String server);

  /// An alias or matrix.to link, resolved and previewed. Throws
  /// [SpaceNotFound] when nothing is there.
  Future<SpacePreview> lookUp(String address);
}
