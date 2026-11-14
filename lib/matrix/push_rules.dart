/// The push rules as the spec and Synapse apply them, judged by the Rust
/// crate `loaf_push` — the same code, and the same verdict, as the iOS
/// Notification Service Extension reaches for a push.
///
/// This used to wrap the SDK's `PushruleEvaluator` and undo three of its
/// departures from the spec by reshaping what it was handed. Those
/// corrections now live in `packages/loaf_push/rust/src/rules.rs`, which
/// takes the ruleset as the server sends it: it checks content rules before
/// room rules, where the SDK has it the other way about and a mentions-only
/// room would silence `.m.rule.contains_user_name`; it skips the legacy
/// body-mention rules for a message carrying `m.mentions`, as Synapse does,
/// so such a message is judged by what it says it mentions; and it decides
/// member-count conditions against the count the server's summary gives,
/// rather than the members the SDK happens to hold in memory, which a room
/// nobody has opened holds few of. One implementation, so the phone and this
/// app cannot disagree.
///
/// It fails open: where the crate cannot judge a message, this says notify.
/// A notification you did not need is a smaller harm than a mention you
/// never saw.
library;

import 'package:loaf_push/loaf_push.dart' as push;
import 'package:matrix/matrix.dart';

class PushRules {
  PushRules(this.client);

  final Client client;

  bool notifies(Event event) {
    final rules = client.globalPushRules;
    final userId = client.userID;
    if (rules == null || userId == null) return true;
    final room = event.room;
    final json = event.toJson();
    // The SDK's evaluator put the room id into the event before matching,
    // and the rules that silence a room match on it, so without this every
    // muted room would notify.
    json['room_id'] = room.id;
    return push.notifies(
          userId: userId,
          // Your name in this room, which is what `contains_display_name`
          // reads — not the profile name, which can differ per room.
          displayName: room
              .unsafeGetUserFromMemoryOrFallback(userId)
              .displayName,
          rules: rules.toJson(),
          event: json,
          // The server's count where it gives one, and otherwise the members
          // known here, as the SDK's evaluator did: a room whose member list
          // the server has refused is judged by what is known, and judged
          // again when the next message asks. The extension has no members
          // in memory to fall back on, so there a count can be unknown, and
          // the crate holds count conditions rather than dropping them.
          members:
              room.summary.mJoinedMemberCount ??
              room.getParticipants([Membership.join]).length,
          power: room.getState(EventTypes.RoomPowerLevels)?.content,
        ) ??
        true;
  }
}
