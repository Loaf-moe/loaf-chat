# loaf native — the timeline (SDK phase 3)

Phase 3 of `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`: a
conversation's messages come from the SDK, and reading, sending, replying,
reacting, editing, deleting, read markers and paging back all reach the real
account. It amends, and never contradicts,
`2026-09-20-loaf-native-design.md` (the authority for message actions and
sending) and `2026-09-26-rooms-from-sync-design.md` (the `Rooms` seam and
the honest-controls rule on a half-wired backend).

## Scope

**In:**

- Reading a room's text messages (`m.text`, `m.notice`, `m.emote`), with
  their edits, reactions and replies folded in.
- Sending text, replying, reacting and un-reacting, editing and deleting your
  own messages, all through the SDK, with honest sending and failed states.
- Encrypted rooms open, but show each undecryptable event as a locked row
  and replace the composer with a note (phase 4 makes them readable).
- Read markers: opening a room marks it read, and so does a new message
  arriving while you are looking. *Mark as read* in the channel menu is
  turned on.
- Paging back through history.
- The default backend becomes `matrix`.

**Out, and when each arrives:**

| Deferred | Phase | Why |
|---|---|---|
| Decrypting, and sending in encrypted rooms | 4 | E2EE |
| Images and files drawn as media | 9 | They show as a `📎 filename` row until then |
| Typing indicators | later | New UI the spec does not draw |
| Read receipts under messages | later | New UI |
| The unread divider, the jump-to-newest pill | later | New UI |
| State events (joins, renames, topics) as timeline lines | later | New UI; they are skipped |
| Rich (HTML) message formatting | later | Plain text until then |
| Fetching a reply's target that is not loaded | later | A stub quote until then |
| Evicting cached timelines | later | Every opened room stays open; fine at loaf.moe's size |

These join the roadmap as **"Deferred from phase 3"**.

**Mock mode is unchanged in every respect**, and stays selectable with
`--dart-define=LOAF_BACKEND=mock`.

## The seam

`Timeline` (`lib/ui/channel/timeline.dart`) is the interface the channel view
draws from. It is a `Listenable` and carries:

- **Reading:** `messages` (oldest first) and `you`.
- **Actions:** `send`, `toggleReaction`, `saveEdit`, `delete`, and
  `retry(messageId)` / `discard(messageId)` for a message that did not send.
- **Paging:** `canLoadOlder`, `loadingOlder`, `loadOlderFailed`, `loadOlder()`.
- **The composer's aim:** `target`, `startReply`, `startEdit`, `clearTarget`,
  implemented once by a `ComposerAiming` mixin both backends use.

`TimelineController` keeps its name and file and becomes the mock
implementation, so `timeline_controller_test.dart` and
`message_actions_test.dart` pass unchanged. It never pages (`canLoadOlder`
is false), its `retry` and `discard` do nothing, and `addCall` stays on it
alone: the shell's mock-only `_onCallRecord` is the only caller, and calls
stay hidden on the matrix backend.

`MatrixTimeline` (`lib/matrix/matrix_timeline.dart`) wraps one SDK
`Timeline`.

`Rooms` gains `Timeline? timeline(String roomId)`, null where the backend has
no `RoomAbility.messages`. `MockRooms` takes over today's `_timelineFor`
logic (the space channels share one mock conversation; every Home room and
anything joined this session has its own), including the DM-bumping
`_activity` listener. `app_shell.dart` stops building timelines.
`MatrixRooms` opens each room's timeline lazily, caches it, and disposes
them all in its `dispose`, which sign-out runs.

## Model changes

All default, so fixtures are untouched:

- `Message.status`: `sent`, `sending` or `failed`.
- `Message.locked`: an encrypted event this device cannot read yet.
- `Message.replyTo` may be a **stub**: a `Message` with `stub: true`, its
  author where known ("someone" otherwise) and no body, drawn as
  "a message further up".

## Mapping

`MatrixTimeline.messages` maps the SDK timeline's events on every read,
reversed from the SDK's newest-first. There is no second store.

- **Rows:** `m.room.message` with `m.text`, `m.notice` or `m.emote` (drawn
  as "*name* waves"). File, image, audio and video msgtypes become a plain
  `📎 filename` row. An undecryptable `m.room.encrypted` becomes a locked
  row. Everything else is skipped: state events, reactions and edits (folded
  into their target), redactions themselves, unknown types.
- **Body:** `getDisplayEvent(timeline)` (the newest edit by the original
  sender) through `calcUnlocalizedBody(hideReply: true, plaintextBody: true)`,
  so the reply fallback is stripped and formatting falls back to plain text.
  `edited` is whether an `m.replace` aggregate exists. An edit by anyone but
  the sender is ignored.
- **Reactions:** `m.annotation` aggregates grouped by key; `count` is the
  number of distinct senders, `mine` whether you are one. Echoes that failed
  to send are ignored, so a failed reaction snaps back.
- **Replies:** `inReplyToEventId` is looked up among the loaded events and
  mapped one level deep (a quote never quotes). Not loaded, or redacted: a
  stub.
- **Redacted messages** are dropped, as the mock's `delete` drops them. The
  spec treats delete as gone.
- **Authors:** `senderFromMemoryOrFallback`, mapped as `MatrixRooms` maps
  members (name, role colour, initials, `you` for your own id). The SDK
  loads unknown senders lazily and its update redraws the name.
- **Status:** SDK `sending` → `sending`, `error` → `failed`, `sent` and
  `synced` → `sent`.
- **Id:** the event id, or the transaction id until the server gives one.
  The SDK swaps the echo in place, so the row does not jump.

Grouping stays with `groupTimeline`.

## Sending, failure and retry

- `send` → `room.sendTextEvent(body, inReplyTo: event)`. The local echo draws
  at once, dimmed while `sending`.
- `saveEdit` → `sendTextEvent(body, editEventId: id)`. Blank or unchanged
  text never sends, as in the mock.
- `toggleReaction` → `redactEvent` on your existing reaction with that key,
  or `sendReaction` if there is none.
- `delete` → `redactEvent`. There is no local echo; the row goes when the
  redaction syncs back.
- **A message that did not send** (the SDK has retried and marked it
  `error`) shows "didn't send" with **retry** (`event.sendAgain()`) and
  **discard** (`event.cancelSend()`). It is never a dead end.
- **A failed reaction, edit or delete** has no row of its own: the mapping
  ignores failed echoes, so the screen snaps back to what the server has,
  and the shell's toast says "couldn't react", "couldn't save that edit" or
  "couldn't delete that".
- **While a message is sending,** it offers only Copy: reacting to, editing
  or deleting it needs an event id it does not have yet.
- No spinners or cancel buttons on steps that cannot be stopped.
- Offline sends go the same way: dim while the SDK retries, then "didn't
  send". Nothing is queued across relaunches, but the SDK keeps a failed
  echo, so it comes back after a relaunch still offering retry.

## Encrypted rooms before phase 4

The timeline opens. Each event that does not decrypt is a dim italic row,
"encrypted · readable once this device is verified", with no actions. The
composer is replaced by one line, "sending here waits for encryption".
Nothing is sent into an encrypted room.

## Read markers

- `MatrixRooms` gains `RoomAbility.markRead`. `markRead(roomId)` sets the
  fully-read marker and a public receipt on the room's last event
  (`room.setReadMarker(id, mRead: id)`). The shell already marks read on
  opening a room when this ability exists, and shows *Mark as read*.
- **While a room is open,** each newly synced message from someone else
  marks it read again, but only while the app is resumed and focused. At
  most one receipt per room is in flight; a burst coalesces.
- Unread counts come from the SDK's `notificationCount` and drop when the
  receipt syncs back. They are never zeroed ahead of the server.
- A failed receipt is silent: the count stays, and the next open tries again.

## Opening and paging

- `Rooms.timeline` returns a `MatrixTimeline` at once; it opens the SDK
  timeline (`room.getTimeline`) behind it. Until that lands `loadingOlder` is
  true, so the top of the list shows the same quiet loading row paging does.
- Scrolling to within about a screen of the top calls `loadOlder()`
  (`requestHistory(historyCount: 50)`). A "loading older messages" row sits
  at the top while it runs. At the room's creation event `canLoadOlder`
  goes false and paging stops.
- A failed page turns that row into "couldn't load older messages ·
  try again".
- The list is a reversed `ListView`, so older rows insert without moving
  what you are reading, and it stays pinned to the newest message when you
  are already there. Scrolled up, nothing moves under you.

## Default backend

`main.dart`'s `LOAF_BACKEND` defaults to `matrix`. `mock` still selects the
mock for previews and the debug levers. The roadmap's status line records
the flip.

## Testing

- **Offline real-SDK tests** (`test/matrix/matrix_timeline_test.dart`, over
  phase 2's `FakeMatrixApi` harness and `handleSync` injection): every
  mapping rule above, including an edit by someone else, reactions counted
  per sender and after redaction, a loaded reply and a stub, a redacted
  message dropped. Sending: echo `sending` then `sent`; an API error to
  `failed`, then `retry` and `discard`. Reaction toggling both ways; failed
  reaction and edit snap back. Paging to the room's creation, and a failed
  page retried. `markRead`'s receipt, and coalescing.
- **Relaunch:** dispose the client, reopen the file-backed database, and the
  timeline and a failed echo come back.
- **Widget tests** over `_FakeRooms` with a fake `Timeline`: sending rows
  dimmed and action-less, the failed row's retry and discard, a locked row
  and the encrypted composer note, the loading and failed-paging rows,
  marking read on a new message only while resumed.
- **Every existing test passes unchanged.**
- **By hand, with Chris driving,** in the unencrypted DM between his account
  and the `hermes` service account (the only room test messages are sent
  in): send, reply, react, edit and delete from both sides; page back;
  relaunch; unreads clear on opening; an encrypted room shows locked rows
  and the composer note; losing the network mid-send gives "didn't send",
  retry and discard.

## Found while rehearsing

The plan (`2026-09-27-timeline.md`) was rehearsed against this spec. These
points were settled there:

- **Two existing tests change, and only mechanically.** The shell test's
  `_FakeRooms` gains `timeline()` returning null, since it implements
  `Rooms`. `matrix_rooms_test`'s abilities assertion grows with each
  ability turned on. It is the one assertion whose meaning is the change.
- **Text is sent exactly as written.** The SDK's `sendTextEvent` runs slash
  commands by default, so typing `/leave` or `/ban` would do it with no
  confirmation. It also turns markdown into HTML by default. Both are off,
  so what you see is what went out.
- **The receipt is public on purpose.** The SDK also sends a private
  receipt alongside it.
- **Failed edits snap back.** The SDK's `getDisplayEvent` does not skip an
  edit that failed to send, so `MatrixTimeline` picks the display event
  itself (the newest non-failed edit by the author).
- **The channel view's list is keyed by its timeline.** Before this it kept
  listening to the room it first showed. With the mock that was invisible;
  a real room's new messages would not have redrawn after switching.
- **A message on its way when the app quit comes back failed.** The SDK
  restores its echo as "sending" but never sends it again, which would
  leave it dimmed for ever with no way forward. `MatrixTimeline` knows
  which transactions it has in flight; any other sending echo reads as
  failed, with retry and discard.
- **A second tap on a reaction before the first reaches the server does
  nothing.** Without that, the reaction was sent twice: its echo is not in
  the timeline yet when the second tap looks for it.
- **A voice channel still shows the unwired line on a backend with messages
  but no calls.** Otherwise it would offer to join through the mock call
  controller.
