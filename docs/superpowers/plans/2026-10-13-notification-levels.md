# Notification levels

**Goal:** A channel has three notification levels, chosen from its menu and
synced to every device as Matrix push rules; the account has a default for
channels, chosen in Settings. Replaces the one bell-off toggle, which wrote
a full mute while its text promised mentions-only.

**Spec:** `docs/superpowers/specs/2026-10-06-notifications-design.md`,
"Settings" and the mute finding.

## The levels

| Level | Push rule | Mentions |
|---|---|---|
| all messages | none | reach you |
| mentions only | `room` kind, `rule_id` = room id, no actions | reach you |
| mute | `override` kind, `event_match room_id`, no actions | silenced |

The SDK's `PushRuleState.notify / mentionsOnly / dontNotify` are these;
`Room.setPushRuleState` sends the delete and put pairs between them.

The account default is `.m.rule.message` and `.m.rule.encrypted` enabled
(all messages) or disabled (mentions only). `.m.rule.encrypted` is written
first and `.m.rule.message` second: the second is the one read back, so a
first write that fails changes nothing anyone sees, and the next attempt
redoes both. Direct messages notify through `.m.rule.room_one_to_one` and
`.m.rule.encrypted_room_one_to_one` either way.

## Where it lives

- `NotifyLevel` and `Channel.notify` in `lib/ui/model/models.dart`;
  `Rooms.setNotify` and `RoomAbility.notify` in `lib/ui/rooms/rooms.dart`.
- `ChannelDefault`, `Profile.channelDefault`, `setChannelDefault` and
  `settingChannelDefault` in `lib/ui/shell/profile.dart`.
- `MatrixRooms` maps `pushRuleState` both ways and keeps the wish until a
  sync agrees, as favourite and low priority do.
- `MatrixProfile` reads the default off `.m.rule.message`, writes both
  rules with a turn counter so a failed older write never undoes a newer
  choice, and follows a change from elsewhere only while no write of its
  own is out.
- The channel menu (`lib/ui/shell/channel_actions.dart`) offers the two
  levels the channel is not at: All messages, Mentions only, Mute. The row
  draws bell-off for mute and bell-minus for mentions only.
- Settings, Notifications: "everywhere you're signed in" with the two
  choices and the line that direct messages always notify. Shown only when
  the dialog has a `ProfileController`.

## Tests

- `test/matrix/matrix_rooms_test.dart`: each level read off its rule, an
  override beside a room rule reads as mute, the six transitions and the
  calls they send, the wish and its rollback.
- `test/matrix/matrix_profile_test.dart`, "channel default": the read,
  write order, each refusal, a later choice over a failing one, a change
  from elsewhere, and a sync during a write.
- `test/app_shell_test.dart`, "channel actions": the menu's offer per
  level and the row's icon.
- `test/notifications_section_test.dart`: the account group, with and
  without a profile, and the spinner while a choice is in flight.
- `test/matrix/matrix_arrivals_test.dart`: a mentions-only room lets a
  mention through; a muted room lets nothing through.
