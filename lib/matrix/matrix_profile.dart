/// [Profile] over the SDK: your presence and status message, and what the
/// server has told us of everyone else's. See "Presence and status" in the
/// phase 6 design spec.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' hide Presence, Profile;

import '../ui/members/presence.dart';
import '../ui/model/models.dart';
import '../ui/shell/profile.dart';
import '../ui/spaces/add_space.dart' show spaceColorFor;

class MatrixProfile extends ChangeNotifier implements Profile {
  /// [identity] is you as the rooms know you (name, avatar); left out, the
  /// localpart stands in.
  MatrixProfile(this.client, {this.identity}) {
    _subscriptions = [
      // Presence rides on the sync, after the SDK has stored it.
      client.onSync.stream.listen(_onSync),
      client.onSyncStatus.stream.listen(_onSyncStatus),
    ];
    unawaited(_loadOwnStatus());
    // The status stream does not replay, and a sync may already be done.
    final status = client.onSyncStatus.value;
    if (status != null) _onSyncStatus(status);
  }

  final Client client;
  final Member Function()? identity;
  late final List<StreamSubscription<Object?>> _subscriptions;
  var _disposed = false;

  var _choice = PresenceChoice.online;
  var _status = '';
  var _shared = true;

  /// Everyone heard from, this session or the database.
  final _heard = <String, (Presence, String?)>{};

  /// Ids already looked up in the database, so each is asked for once.
  final _asked = <String>{};

  /// Counts writes, so a failed older one doesn't undo a newer wish.
  var _choiceTurn = 0;
  var _statusTurn = 0;

  var _published = false;

  @override
  PresenceChoice get choice => _choice;

  @override
  String get status => _status;

  @override
  bool get presenceShared => _shared;

  @override
  Member get me {
    final id = client.userID ?? '';
    final base =
        identity?.call() ?? Member(id, id.localpart ?? id, spaceColorFor(id));
    return base.copyWith(presence: _choice.shown, statusMessage: _status);
  }

  @override
  (Presence, String?)? presenceOf(String userId) {
    final heard = _heard[userId];
    if (heard == null && _asked.add(userId)) unawaited(_load(userId));
    return heard;
  }

  /// A person the sync has not mentioned this session may still be in the
  /// database. Nothing found is null, not offline: `fetchCurrentPresence`
  /// would say offline, and loaf never calls it.
  Future<void> _load(String userId) async {
    try {
      final stored = await client.database.getPresence(userId);
      if (_disposed || stored == null || _heard.containsKey(userId)) return;
      // The database keeps no busy; that only ever comes from the wire.
      _heard[userId] = (_shown(stored.presence.name), stored.statusMsg);
      _notify();
    } catch (_) {
      // Unread is the same as unheard.
    }
  }

  Future<void> _loadOwnStatus() async {
    try {
      final stored = await client.database.getPresence(client.userID!);
      // Not over something typed since.
      if (_disposed || stored == null || _statusTurn > 0) return;
      final status = stored.statusMsg ?? '';
      if (status == _status) return;
      _status = status;
      _notify();
    } catch (_) {
      // Then it starts empty.
    }
  }

  void _onSync(SyncUpdate update) {
    final events = update.presence;
    if (_disposed || events == null || events.isEmpty) return;
    for (final event in events) {
      // Raw, because the SDK's own enum has no busy and reads it as offline.
      final content = event.content;
      _heard[event.senderId] = (
        _shown(content['presence']),
        content['status_msg'] as String?,
      );
    }
    // Someone's presence arrived, so the server shares it.
    _shared = true;
    _notify();
  }

  static Presence _shown(Object? wire) => switch (wire) {
    'online' => Presence.online,
    'unavailable' => Presence.idle,
    'busy' => Presence.dnd,
    _ => Presence.offline,
  };

  void _onSyncStatus(SyncStatusUpdate update) {
    if (_disposed || _published || update.status != SyncStatus.finished) return;
    _published = true;
    unawaited(_publish());
  }

  /// Most choices travel on the sync, so this one write is also the question
  /// "does this server share presence at all?". A refusal answers no; a
  /// failure that says nothing about it decides nothing.
  Future<void> _publish() async {
    try {
      await client.setPresence(
        client.userID!,
        _wire(_choice),
        statusMsg: _status,
      );
    } on MatrixException catch (e) {
      final code = e.errcode;
      final http = e.response?.statusCode;
      if (code == 'M_FORBIDDEN' ||
          code == 'M_UNRECOGNIZED' ||
          http == 403 ||
          http == 404) {
        if (_disposed) return;
        _shared = false;
        _notify();
      }
    } catch (_) {
      // Offline, a timeout: try again next session.
    }
  }

  // DND is unavailable until it has its own wire form.
  static PresenceType _wire(PresenceChoice c) => switch (c) {
    PresenceChoice.online => PresenceType.online,
    PresenceChoice.idle || PresenceChoice.dnd => PresenceType.unavailable,
    PresenceChoice.invisible => PresenceType.offline,
  };

  @override
  Future<void> choose(PresenceChoice choice) async {
    final previous = _choice;
    final turn = ++_choiceTurn;
    _choice = choice;
    client.syncPresence = _wire(choice);
    _notify();
    try {
      await client.setPresence(
        client.userID!,
        _wire(choice),
        statusMsg: _status,
      );
    } catch (_) {
      // Back only if nobody has chosen since: that wish stands.
      if (!_disposed && turn == _choiceTurn) {
        _choice = previous;
        client.syncPresence = _wire(previous);
        _notify();
      }
      rethrow;
    }
  }

  @override
  Future<void> setStatus(String status) async {
    final trimmed = status.trim();
    final previous = _status;
    final turn = ++_statusTurn;
    _status = trimmed;
    _notify();
    try {
      await client.setPresence(
        client.userID!,
        _wire(_choice),
        statusMsg: trimmed,
      );
    } catch (_) {
      if (!_disposed && turn == _statusTurn) {
        _status = previous;
        _notify();
      }
      rethrow;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    super.dispose();
  }
}
