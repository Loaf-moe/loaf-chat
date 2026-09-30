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
      // The SDK marks your cached profile outdated when your own member
      // event changes, here or on another device.
      client.onUserProfileUpdate.stream.listen(_onProfileUpdate),
    ];
    unawaited(_loadProfile());
    // What was chosen, on this or another device; nothing is sent for it.
    _choice = _reconcile(_stored, client.allPushNotificationsMuted);
    client.syncPresence = _syncWire(_choice);
    _ownStatus = _loadOwnStatus();
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

  /// Status writes in flight. Your own presence coming back on the sync
  /// while one is out is older than it, and must not undo it.
  var _statusWrites = 0;

  var _published = false;

  /// What the server has for you; null until it has said, or when it has no
  /// name (a blank one is no name).
  String? _name;
  AvatarRef? _avatar;

  /// Bumped by every local write to the above, so a fetch that started
  /// before it can't put back what it replaced.
  var _profileTurn = 0;

  var _saving = 0;
  var _uploading = false;

  /// Automatic idle is on: nobody is at this device.
  var _away = false;

  /// Choices in flight. The account data and push rule they write come back
  /// on the sync half-finished, and must not be mistaken for someone else's.
  var _choosing = 0;

  static const _accountType = 'moe.loaf.presence';

  /// The stored own status, read at start. The publish waits on it so it
  /// never sends an empty status over the one the server has.
  late final Future<void> _ownStatus;

  @override
  PresenceChoice get choice => _choice;

  @override
  String get status => _status;

  @override
  bool get presenceShared => _shared;

  /// The name the server has, or null while it hasn't said.
  String? get loadedName => _name;

  @override
  String get displayName {
    final id = client.userID ?? '';
    return _name ?? id.localpart ?? id;
  }

  @override
  AvatarRef? get avatar => _avatar;

  @override
  bool get savingAccount => _saving > 0;

  @override
  bool get uploadingAvatar => _uploading;

  @override
  Member get me {
    final id = client.userID ?? '';
    final base =
        identity?.call() ?? Member(id, id.localpart ?? id, spaceColorFor(id));
    return base.copyWith(
      name: _name,
      avatar: _avatar,
      presence: _choice.shown,
      statusMessage: _status,
    );
  }

  void _onProfileUpdate(String userId) {
    if (_disposed || userId != client.userID) return;
    unawaited(_loadProfile());
  }

  /// [fresh] skips the SDK's cache, for right after a write of ours (which
  /// the SDK doesn't know to mark outdated).
  Future<void> _loadProfile({bool fresh = false}) async {
    final turn = _profileTurn;
    try {
      final profile = await client.getUserProfile(
        client.userID!,
        maxCacheAge: fresh ? Duration.zero : const Duration(days: 1),
      );
      if (_disposed || turn != _profileTurn) return;
      final name = profile.displayname?.trim();
      final next = name == null || name.isEmpty ? null : profile.displayname;
      final avatar = AvatarRef.maybe(profile.avatarUrl?.toString());
      if (next == _name && avatar == _avatar) return;
      _name = next;
      _avatar = avatar;
      _notify();
    } catch (_) {
      // Offline: what was shown stands, and a member event tries again.
    }
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

  String? get _stored {
    final choice = client.accountData[_accountType]?.content['choice'];
    return choice is String ? choice : null;
  }

  /// The push rule is account-wide and does the silencing, so it decides:
  /// muted is do not disturb whatever was stored, and a stored do not
  /// disturb with the rule off (someone unmuted elsewhere) is online. Never
  /// leaves your devices silently muted behind a choice that says otherwise.
  static PresenceChoice _reconcile(String? stored, bool muted) {
    if (muted) return PresenceChoice.dnd;
    if (stored == PresenceChoice.dnd.name) return PresenceChoice.online;
    return PresenceChoice.values.asNameMap()[stored] ?? PresenceChoice.online;
  }

  /// Follows a change made elsewhere. Sends nothing: a remote change is
  /// followed, not fought, and a reconcile never mutes on its own.
  void _follow() {
    final next = _reconcile(_stored, client.allPushNotificationsMuted);
    client.syncPresence = _syncWire(next);
    if (next == _choice) return;
    _choice = next;
    _notify();
  }

  void _onSync(SyncUpdate update) {
    if (_disposed) return;
    final account = update.accountData;
    if (_choosing == 0 &&
        account != null &&
        account.any(
          (e) => e.type == _accountType || e.type == EventTypes.PushRules,
        )) {
      _follow();
    }
    final events = update.presence;
    if (events == null || events.isEmpty) return;
    for (final event in events) {
      // Raw, because the SDK's own enum has no busy and reads it as offline.
      final content = event.content;
      _heard[event.senderId] = (
        _shown(content['presence']),
        content['status_msg'] as String?,
      );
      // Another of your devices set a status: follow it, or the next
      // presence write from here (automatic idle sends one on every
      // backgrounding) puts this device's stale text back over it.
      if (event.senderId == client.userID && _statusWrites == 0) {
        _status = (content['status_msg'] as String?) ?? '';
      }
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
    await _ownStatus;
    if (_disposed) return;
    try {
      await _put(_choice);
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

  /// What the sync carries. Do not disturb rides as unavailable there and
  /// gets its busy from [_put]; automatic idle only softens online.
  PresenceType _syncWire(PresenceChoice c) =>
      _away && c == PresenceChoice.online ? PresenceType.unavailable : _wire(c);

  static PresenceType _wire(PresenceChoice c) => switch (c) {
    PresenceChoice.online => PresenceType.online,
    PresenceChoice.idle || PresenceChoice.dnd => PresenceType.unavailable,
    PresenceChoice.invisible => PresenceType.offline,
  };

  /// One presence write for [c], with the status. The SDK's enum has no
  /// busy, so do not disturb is a raw PUT.
  Future<void> _put(PresenceChoice c) async {
    final me = client.userID!;
    if (c == PresenceChoice.dnd) {
      try {
        await client.request(
          RequestType.PUT,
          '/client/v3/presence/${Uri.encodeComponent(me)}/status',
          data: {'presence': 'busy', 'status_msg': _status},
        );
        return;
      } on MatrixException {
        // A server with no busy: others see idle, and the devices are still
        // silenced by the push rule.
      }
    }
    await client.setPresence(me, _syncWire(c), statusMsg: _status);
  }

  /// Both halves of do not disturb, tried independently so that what stuck
  /// is known. Throws [HalfApplied] when only one did, and the first error
  /// when neither did.
  Future<void> _silence() async {
    Object? refused;
    try {
      await _put(PresenceChoice.dnd);
    } catch (e) {
      refused = e;
    }
    Object? unmuted;
    try {
      await client.setMuteAllPushNotifications(true);
    } catch (e) {
      unmuted = e;
    }
    if (refused == null && unmuted == null) return;
    if (refused != null && unmuted != null) throw refused;
    _muteLanded = unmuted == null;
    throw const HalfApplied();
  }

  var _muteLanded = false;

  @override
  Future<void> choose(PresenceChoice choice) async {
    final previous = _choice;
    final turn = ++_choiceTurn;
    _choice = choice;
    client.syncPresence = _syncWire(choice);
    _choosing++;
    _notify();
    var unmuted = false;
    try {
      // Leaving do not disturb unmutes before anything else goes out.
      if (previous == PresenceChoice.dnd && choice != PresenceChoice.dnd) {
        await client.setMuteAllPushNotifications(false);
        unmuted = true;
      }
      if (choice == PresenceChoice.dnd) {
        await _silence();
      } else {
        await _put(choice);
      }
      await _remember(choice);
    } catch (e) {
      // Back only if nobody has chosen since: that wish stands.
      if (!_disposed && turn == _choiceTurn) {
        // Where things really are: a half-applied dnd is what the rule says,
        // and once unmuted there is no going back to dnd.
        _choice = e is HalfApplied
            ? _reconcile(_stored, _muteLanded)
            : unmuted
            ? _reconcile(_stored, false)
            : previous;
        client.syncPresence = _syncWire(_choice);
        _notify();
      }
      rethrow;
    } finally {
      _choosing--;
    }
  }

  /// So your other devices, and the next launch, know what was chosen: the
  /// server cannot tell "chose idle" from "went idle". Best effort; the push
  /// rule still says whether you are silenced.
  Future<void> _remember(PresenceChoice choice) async {
    try {
      await client.setAccountData(client.userID!, _accountType, {
        'choice': choice.name,
      });
    } catch (e) {
      Logs().v('could not store the presence choice', e);
    }
  }

  @override
  void away(bool away) {
    if (_disposed || away == _away) return;
    _away = away;
    // Only online is softened; going away from anything else is nothing.
    if (away && _choice != PresenceChoice.online) return;
    unawaited(_sendAway());
  }

  Future<void> _sendAway() async {
    final choice = _choice;
    client.syncPresence = _syncWire(choice);
    try {
      await _put(choice);
    } catch (e) {
      // Idle is a courtesy: no toast, and the next sync carries it anyway.
      Logs().v('could not send automatic idle', e);
    }
  }

  @override
  Future<void> setStatus(String status) async {
    final trimmed = status.trim();
    final previous = _status;
    final turn = ++_statusTurn;
    _status = trimmed;
    _statusWrites++;
    _notify();
    try {
      await _put(_choice);
    } catch (_) {
      if (!_disposed && turn == _statusTurn) {
        _status = previous;
        _notify();
      }
      rethrow;
    } finally {
      _statusWrites--;
    }
  }

  @override
  Future<void> saveAccount({
    required String displayName,
    required String status,
  }) async {
    final name = displayName.trim();
    final trimmed = status.trim();
    // A blank name is no change: the server would keep it blank.
    final nameChanged = name.isNotEmpty && name != this.displayName;
    final statusChanged = trimmed != _status;
    if (!nameChanged && !statusChanged) return;
    _saving++;
    _notify();
    var nameFailed = false;
    var statusFailed = false;
    try {
      if (nameChanged) {
        final turn = ++_profileTurn;
        try {
          await client.setProfileField(client.userID!, 'displayname', {
            'displayname': name,
          });
          if (!_disposed && turn == _profileTurn) {
            _name = name;
            _notify();
          }
        } catch (_) {
          nameFailed = true;
        }
      }
      if (statusChanged) {
        try {
          await setStatus(trimmed);
        } catch (_) {
          statusFailed = true;
        }
      }
    } finally {
      _saving--;
      _notify();
    }
    if (_disposed || !(nameFailed || statusFailed)) return;
    throw AccountSaveFailed(name: nameFailed, status: statusFailed);
  }

  @override
  Future<void> setAvatar(Uint8List? png) async {
    // The button is disabled meanwhile; this is the backstop, and a loud
    // one: returning quietly would look like the picture had been set.
    if (_uploading) throw StateError('a picture is already being uploaded');
    _uploading = true;
    _notify();
    try {
      await client.setAvatar(
        png == null
            ? null
            : MatrixImageFile(
                bytes: png,
                name: 'avatar.png',
                mimeType: 'image/png',
              ),
      );
      _profileTurn++;
      if (png == null && !_disposed) {
        _avatar = null;
        _notify();
      }
    } finally {
      _uploading = false;
      _notify();
    }
    // The upload's uri isn't handed back, so ask the server what it has.
    if (png != null) await _loadProfile(fresh: true);
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
