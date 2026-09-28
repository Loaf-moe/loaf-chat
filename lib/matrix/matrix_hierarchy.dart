/// Each joined space's tree from `/hierarchy`, read once and kept until
/// told to look again. It fills in what the SDK's own room state cannot:
/// the name, topic, kind and join rule of a channel nobody here has
/// joined, and the children of a subspace nobody here has joined either.
/// The one extra cache `MatrixRooms` keeps beside its pending overlay.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

class MatrixHierarchy {
  MatrixHierarchy(this.client, {required this.onChange});

  final Client client;
  final VoidCallback onChange;

  var _disposed = false;

  /// The last tree a fetch landed for each space, kept on screen even
  /// while stale or refetching, so nothing flickers to nothing.
  final _trees = <String, List<SpaceRoomsChunk$2>>{};

  /// Spaces with a fetch under way, so [children] does not start a second.
  final _fetching = <String>{};

  /// Spaces whose last fetch failed, so [children] does not retry until
  /// [invalidate] says the tree may have changed.
  final _failed = <String>{};

  /// Spaces [invalidate] has marked as needing another look.
  final _stale = <String>{};

  /// The space's children the server told us of, or null before the first
  /// fetch lands. Starts a fetch when there is none under way and the
  /// tree is missing, stale, or has never been tried.
  List<SpaceRoomsChunk$2>? children(String spaceId) {
    final wants = !_trees.containsKey(spaceId) || _stale.contains(spaceId);
    if (wants && !_fetching.contains(spaceId) && !_failed.contains(spaceId)) {
      unawaited(_fetch(spaceId));
    }
    return _trees[spaceId];
  }

  Future<void> _fetch(String spaceId) async {
    _fetching.add(spaceId);
    _stale.remove(spaceId);
    try {
      final rooms = <SpaceRoomsChunk$2>[];
      String? from;
      do {
        final page = await client.getSpaceHierarchy(spaceId, from: from);
        rooms.addAll(page.rooms);
        from = page.nextBatch;
      } while (from != null);
      _trees[spaceId] = rooms;
      _failed.remove(spaceId);
    } on Object {
      // Keep whatever tree is already there; don't try again on our own.
      _failed.add(spaceId);
    } finally {
      _fetching.remove(spaceId);
    }
    if (!_disposed) onChange();
  }

  /// Drops [spaceId]'s tree, so the next [children] fetches again.
  void invalidate(String spaceId) {
    _stale.add(spaceId);
    _failed.remove(spaceId);
  }

  /// Servers to join [roomId] through: the `via` of the `m.space.child`
  /// that lists it, in whichever cached tree carries it.
  List<String> via(String roomId) {
    for (final tree in _trees.values) {
      for (final chunk in tree) {
        for (final child in chunk.childrenState) {
          if (child.stateKey == roomId) {
            return child.content.tryGetList<String>('via') ?? const [];
          }
        }
      }
    }
    return const [];
  }

  void dispose() {
    _disposed = true;
  }
}
