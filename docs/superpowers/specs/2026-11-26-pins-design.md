# Loaf Chat — Pinned messages

A room has no way to keep a message at hand. This spec adds pins, shaped
like Discord's: a pin action on a message's menu for those allowed, a pin
button in the channel header that opens the list of pinned messages, a tap
on one that jumps to it, and a line in the conversation saying who pinned
what. Pins are Matrix's `m.room.pinned_events` room state, so every client
sees the same list.

It is not a phase of `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`.
It builds on the timeline of `2026-09-27-timeline-design.md` and the jump of
`2026-10-06-notifications-design.md` (section B).

## Scope

**In:**

- Pin and Unpin on a message's actions, for people the room's power levels
  allow to change its pinned events.
- A pin button in the channel header, for every conversation with a
  timeline, DMs included. It opens the pinned list: a popover under the
  button on a computer, a sheet on a phone.
- Each pinned message drawn whole in that list, newest pin first, fetched
  from the server when it is not loaded. A tap jumps to it. Unpin on the
  row, for those allowed.
- A line in the conversation when someone pins: "mika pinned a message".
  A tap jumps to it.
- The mock backend pins too, so tests and previews draw all of it.

**Out:**

| Deferred | Why |
|---|---|
| A mark on a pinned message's row | Discord draws none; the list is where pins are read |
| A line when someone unpins | Discord draws none |
| Confirming a pin or an unpin | Both undo in one tap; only redaction asks, as elsewhere in loaf |
| A cap on pins | Discord's 50 is its limit, not its shape; Matrix has none |
| The list changing before the server answers | A pin is room state the next sync brings back within a second on loaf.moe; a wish would be a second source of truth |
| Edits of a pinned message that is not loaded | The fetched event is drawn as sent; its edits live in the conversation, one tap away |
| Pins in the channel list or on a room not open | Nothing there to draw them in; the state is in memory for every room should something want it |
| Searching the pinned list | Message search is a v1 non-goal |

## Findings (checked 2026-11-26)

Sources: `matrix` 13.0.0 in the pub cache, and this repository at `a4393aa`.

**Matrix and the SDK**

- `m.room.pinned_events` is room state with an empty state key. Its content
  is `{"pinned": [eventId, ...]}`, an ordered list. Every change replaces the
  whole list; Matrix has no append and no compare-and-set, so two people
  pinning at once can lose one pin. Element has the same.
- `Room.pinnedEventIds` reads the list, `[]` when there is none.
  `Room.setPinnedEvents(List<String>)` writes it. `EventTypes.RoomPinnedEvents`
  names the type.
- `Room.canChangeStateEvent(EventTypes.RoomPinnedEvents)` says whether you
  may: the room's `events` entry for the type, else `state_default`, else 50.
  So moderators and admins unless the room says otherwise. False when not
  joined. `m.room.power_levels` is in `importantStateEvents`
  (`lib/matrix/client_factory.dart`), so the answer is in memory for every
  room.
- `m.room.pinned_events` is in `importantStateEvents`
  (`lib/matrix/client_factory.dart`), so it is in memory for every room.
  It has to be: the SDK keeps other state in memory only for a room that
  is not `partial` (`client.dart`, `_updateRoomsByEventUpdate`) and loads
  it from the database when `Room.getTimeline` calls `postLoad`, but the
  sync that first brings a room stores none of that other state at all. A
  pinned-events event in that sync's state block reached neither memory
  nor `nonPreloadRoomStateBox`; the same event in a later sync did. Pins
  made before you joined would have been lost until the next pin.
- A state event arriving by sync is also a timeline event. The SDK's
  `Timeline.events` holds it, and `onUpdate` fires, so `MatrixTimeline`
  redraws on a pin. `_message` returns null for every type other than
  message and sticker, which is why no state draws today.
- `Event.prevContent` reads `unsigned.prev_content`. A state event's
  previous content is what tells a pin from an unpin.
- `Room.getEventById(id)` reads the database, then
  `GET /rooms/{id}/event/{eventId}`, decrypting an encrypted event where it
  can. `M_NOT_FOUND` is null; other `MatrixException`s throw.

**This repository**

- `ui.Timeline` (`lib/ui/channel/timeline.dart`) is the seam. `jumpTo`
  brings a loaded message into view and reopens the conversation around one
  that is not. `failures` is the toast line.
- Message actions (`lib/ui/channel/message_actions.dart`) are one list
  for the sheet, the right-click menu and the hover toolbar's "more", built
  by `actionsFor`. Only delete confirms.
- `Message.callLine` is the one line the timeline draws that nobody said.
  `groupTimeline` gives it a `CallEntry` of its own, and
  `channel_view.dart` draws `_CallLineTile`: icon, label, time, centred.
- The header (`_ChannelHeader`) draws call buttons for a DM and a members
  button for everything else, all `_HeaderIconButton`s with tooltips.
- `showAnchoredPopover` (`lib/ui/widgets/anchored_popover.dart`) opens a
  popover beside a rect on a computer, above it where there is room and
  below where there is not, and carries the media scope. The emoji picker
  and the status picker open with it.
- `showActionSheet` is a modal bottom sheet of actions; a sheet with other
  content is `showModalBottomSheet` with the same frame.
- `TimelineController` (`lib/ui/channel/timeline_controller.dart`) is the
  mock timeline. `mockActiveChannel`'s messages are `mockTimeline()`, shared
  by every space channel.

## The seam

### `Timeline`

```dart
/// Pinned messages, in the room's order: oldest pin first.
List<String> get pinnedIds;

/// Whether you may pin and unpin here. Read live, like [writable].
bool get canPin;

/// Pins [messageId]. Nothing changes until the room says so; one already
/// pinned is left alone. A refusal is said in [failures].
void pin(String messageId);

/// Takes [messageId] off the pinned list. One not pinned is left alone. A
/// refusal is said in [failures].
void unpin(String messageId);

/// The message with [id]: the loaded one, else fetched from the server.
/// Null for a message that cannot be had: deleted, never yours to see, or
/// gone. Throws when the server could not be asked.
Future<Message?> fetch(String id);
```

### `Message.pinLine`

`Message` gains `PinLine? pinLine`:

```dart
/// A line saying someone pinned. [pinned] are the ids this event added.
class PinLine {
  const PinLine(this.pinned);
  final List<String> pinned;
}
```

`body` is then its label: "mika pinned a message", or "mika pinned 3
messages". `groupTimeline` gives it a `PinEntry` of its own, as a call line
gets a `CallEntry`. A pin line has no actions and takes no reaction; it is
never a reply target, never edited, never pinned itself.

## Who can pin

`canPin` is `room.canChangeStateEvent(EventTypes.RoomPinnedEvents)`. Pin and
Unpin are offered only when it is true: hidden, not dimmed, since nothing
you do in the room changes it. The mock's `canPin` is true.

## Pinning and unpinning

`MessageAction.pin` and `MessageAction.unpin` sit after Reply and before
Copy text, with `LucideIcons.pin` and `LucideIcons.pinOff`, labelled "Pin
message" and "Unpin message". One of the two is offered, by whether the
message's id is in `pinnedIds`, when all of these hold:

- `canPin`;
- the server has the message (status sent);
- it is not locked: you cannot pin what you cannot read;
- it is not a call line or a pin line.

`writable` does not gate it: a pin is room state, not a message, and an
unverified device may write state in an encrypted room.

`MatrixTimeline.pin` writes `setPinnedEvents([...pinnedEventIds, id])`;
`unpin` writes the list without the id. Both run through `_attempt`, with
"couldn't pin that" and "couldn't unpin that" as the failure lines. Nothing
is shown until the state comes back by sync; the next `onUpdate` redraws
the header, the list and the line.

The mock pins at once: `pinnedIds` gains the id, and a pin line from you
lands at the end of the conversation, as the server's would.

## The pinned list

The header gains a pin button (`LucideIcons.pin`, tooltip "Pinned
messages") before the call buttons or the members button, for every
conversation with a timeline. No count on it.

`PinnedPanel` (`lib/ui/channel/pinned_panel.dart`) is what it opens:

- **A computer:** a popover beside the button, 400 wide, up to 480 high,
  scrolling. Opened with `showAnchoredPopover`, which puts it below the
  button, since the header leaves no room above.
- **A phone:** a modal bottom sheet with a drag handle, up to 85% of the
  screen, scrolling. The sheet's frame is `showActionSheet`'s.

Both read the same `Timeline`, and follow it: a pin or unpin that arrives
while the list is open changes the list.

**Rows,** newest pin first, each: avatar, name and time as a message header
draws them, then the message's words on up to three lines. A picture, a
video, a sound or a file with no caption reads as the reply quote reads one.
A locked message reads as a reply's quote reads one.

- A message loaded in the conversation draws at once. One that is not is
  asked of `fetch`: the row says "loading…" until it answers.
- `fetch` answering null: the row reads "that message isn't available"
  (`messageUnavailable`), with its author unknown.
- `fetch` throwing: the row reads "couldn't load · try again", and a tap on
  it asks again.
- **Tap** on a row that has a message closes the list and calls `jumpTo`.
  A jump to a message the server will not give says so in a toast, as any
  jump does.
- **Unpin** is a trailing `LucideIcons.pinOff` button on every row when
  `canPin`, tooltip "Unpin". It asks nothing. It is offered on an
  unavailable row too: that is how a dead pin is cleared.

**Empty:** the pin icon and "nothing pinned yet", with "pin a message from
its menu" under it when `canPin`.

## The line in the conversation

`MatrixTimeline._message` maps an `m.room.pinned_events` event to a message
with a `pinLine` when it added something: the ids in `content.pinned` that
`prevContent.pinned` does not hold, every id when there is no previous
content. An event that only removed draws nothing. A redacted one draws
nothing, as every redacted event does.

The label names the sender as the rest of the app does: "mika pinned a
message", or "mika pinned 3 messages" for several at once (another client
can write several). The mock writes one id per line.

`_PinLineTile` draws it as `_CallLineTile` draws a call: `LucideIcons.pin`,
the label, the time, centred. A tap on a line that pinned one message calls
`jumpTo` on it; on a line that pinned several, it opens the pinned list.

## Errors

| What | Where it shows |
|---|---|
| The server refuses a pin or an unpin | A toast: "couldn't pin that" / "couldn't unpin that" |
| A pinned message that is deleted or not yours to see | Its row reads unavailable; unpin stays |
| A pinned message that cannot be fetched (offline) | Its row reads "couldn't load · try again" |
| A jump to a pinned message the server will not give | A toast, as every jump: "that message isn't available" |

## Testing

Existing tests pass unchanged, apart from the `_FakeTimeline`s
(`test/channel_view_states_test.dart`, `test/channel_view_media_test.dart`,
`test/channel_view_encryption_test.dart`), which gain the new members.

- **Actions** (`test/message_actions_test.dart`): Pin offered when allowed
  and the message sent; Unpin for a pinned id; neither without `canPin`,
  for a sending message, a locked one, a call line or a pin line; Pin on an
  unwritable timeline; the pick calling `pin` / `unpin`.
- **Grouping** (`test/group_timeline_test.dart`): a pin line is its own
  `PinEntry` and breaks a group.
- **The mock** (`test/timeline_controller_test.dart`): pin adds the id and
  a pin line from you; pin twice adds once; unpin removes; unpin of an
  unpinned id changes nothing; `fetch` finds a loaded message and answers
  null for an unknown id.
- **Mapping** (`test/matrix/matrix_timeline_test.dart`): a pinned-events
  event with one added id draws a line naming it; several added; one that
  only removed draws nothing; no previous content counts every id;
  `pinnedIds` from room state and after a change by sync; `canPin` from
  power levels (allowed, not allowed, named in `events`).
- **Writes** (`test/matrix/matrix_timeline_test.dart`): pin puts the whole
  list with the id appended; pin of a pinned id sends nothing; unpin puts
  the list without it; unpin of an unpinned id sends nothing; a refusal is a
  failure line; disposing mid-pin notifies nothing.
- **Fetch** (`test/matrix/matrix_timeline_test.dart`): a loaded message is
  answered without a request; one not loaded is asked for and mapped; 404
  is null; 403 is null; a redacted event is null; a server error throws.
- **The header** (`test/channel_view_states_test.dart`): the pin button
  for a channel, a room and a DM; none without a timeline.
- **The panel** (`test/pinned_panel_test.dart`): rows newest first; a
  loaded row drawn at once; a fetched row loading then drawn; an
  unavailable row; a failed row and its retry; a tap jumping and closing;
  Unpin shown only with `canPin`, and calling `unpin`; empty with and
  without `canPin`; a pin arriving while open; a popover on a computer and a
  sheet on a phone.
- **The line** (`test/channel_view_states_test.dart`): drawn centred with
  the label; a tap on a one-message line jumping; on a several-message
  line opening the list.

**By hand on loaf.moe:** pin from the menu as a moderator and watch the
line land; the list from the header, with a pin from far back in history
that fetches; jump from the list and from the line; unpin from the list;
whether tuwunel sends `prev_content` for pinned-events over `/messages`,
which decides what old lines say; a plain member seeing no Pin; an
encrypted room from an unverified device pinning.

## Order

1. The seam, the actions, the mock, the mapping and writes in
   `MatrixTimeline`, the header button, the panel and the line, as one
   change.
2. Checks by hand on loaf.moe.
