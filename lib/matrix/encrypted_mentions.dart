/// Keeps mentions reaching the phone from an encrypted channel set to
/// mentions only.
///
/// Mentions only, for one room, is a room-kind push rule with no actions;
/// that is the SDK's `setPushRuleState` and every other client's too. The
/// server checks room rules before underride rules, so that rule stops an
/// encrypted message before `.m.rule.encrypted` can carry it to the device.
/// And the mention rules that come earlier cannot match it: the server
/// cannot see inside the message. The push is never sent, the notification
/// extension never runs, and the mention is lost.
///
/// So each such room also gets an override of ours: this room, type
/// `m.room.encrypted`, notify. Override rules come before room rules, so the
/// encrypted message reaches the device again. There it is judged decrypted,
/// as `m.room.message`, which this override does not match, so the room rule
/// still silences a plain message and the mention rules still let a mention
/// through — on the phone and in the app alike. `.m.rule.master` is checked
/// before any user-defined override, so Do not disturb still wins.
///
/// The override follows the room rule rather than the button that set it,
/// so a room set to mentions only from another client, or one that turns
/// encrypted later, is caught at the next sync too.
library;

import 'dart:async';

import 'package:matrix/matrix.dart';

/// Not leading with a dot: those ids are the server's own.
const _prefix = 'moe.loaf.encrypted_mentions.';

String encryptedMentionsRuleId(String roomId) => '$_prefix$roomId';

/// Brings the account's overrides level with its rooms: one for every
/// joined, encrypted room on mentions only, and none for any other room.
/// Writes nothing when they already agree.
Future<void> reconcileEncryptedMentions(Client client) async {
  final rules = client.globalPushRules;
  if (rules == null) return;
  final have = {
    for (final rule in rules.override ?? const <PushRule>[])
      if (rule.ruleId.startsWith(_prefix))
        rule.ruleId.substring(_prefix.length),
  };
  final want = {
    for (final room in client.rooms)
      if (room.membership == Membership.join &&
          room.encrypted &&
          room.pushRuleState == PushRuleState.mentionsOnly)
        room.id,
  };
  for (final roomId in want.difference(have)) {
    await client.setPushRule(
      PushRuleKind.override,
      encryptedMentionsRuleId(roomId),
      ['notify'],
      conditions: [
        PushCondition(
          kind: PushRuleConditions.eventMatch.name,
          key: 'room_id',
          pattern: roomId,
        ),
        PushCondition(
          kind: PushRuleConditions.eventMatch.name,
          key: 'type',
          pattern: EventTypes.Encrypted,
        ),
      ],
    );
  }
  for (final roomId in have.difference(want)) {
    await client.deletePushRule(
      PushRuleKind.override,
      encryptedMentionsRuleId(roomId),
    );
  }
}

/// Runs [reconcileEncryptedMentions] once the rules are known, and again
/// whenever a sync changes the rules, a room's encryption, or which rooms
/// you are in. One run at a time: a sync that lands mid-run asks for one
/// more after it, so two runs never race to write the same rule.
class EncryptedMentions {
  EncryptedMentions(this.client) {
    _sub = client.onSync.stream.listen(_onSync);
    if (client.globalPushRules != null) _run();
  }

  final Client client;
  late final StreamSubscription<SyncUpdate> _sub;
  var _seenFirst = false;
  var _running = false;
  var _again = false;
  var _disposed = false;

  void dispose() {
    _disposed = true;
    unawaited(_sub.cancel());
  }

  void _onSync(SyncUpdate update) {
    final first = !_seenFirst;
    _seenFirst = true;
    if (first || _matters(update)) _run();
  }

  static bool _matters(SyncUpdate update) {
    if (update.accountData?.any((e) => e.type == 'm.push_rules') ?? false) {
      return true;
    }
    final rooms = update.rooms;
    if (rooms == null) return false;
    if (rooms.leave?.isNotEmpty ?? false) return true;
    // Any state at all, not just m.room.encryption: a room you have just
    // joined arrives as state, and whether it is mentions-only was settled
    // by rules already held. A run that finds nothing to change writes
    // nothing, so being generous here costs only a walk over the rooms.
    return rooms.join?.values.any(
          (room) =>
              (room.state?.isNotEmpty ?? false) ||
              (room.timeline?.events?.any(
                    (e) => e.type == EventTypes.Encryption,
                  ) ??
                  false),
        ) ??
        false;
  }

  Future<void> _run() async {
    if (_disposed) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        try {
          await reconcileEncryptedMentions(client);
        } catch (e, s) {
          // The next sync that matters tries again. Until then the room
          // behaves as it did before this fix, which is no worse.
          Logs().w('Could not reconcile encrypted mention rules', e, s);
        }
      } while (_again && !_disposed);
    } finally {
      _running = false;
    }
  }
}
