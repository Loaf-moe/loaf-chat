# loaf native — calls design

Wave 2's "expanded call UI", widened to cover calls in DMs. Built as a Flutter
mockup on fake data like everything else: real widgets, fake state, no Matrix,
LiveKit, CallKit or push. The protocol notes below exist so the UI maps cleanly
onto MatrixRTC when it is wired; they are not implemented here.

## Scope

- **Voice channels** — drop-in, never ring. The call *is* the channel.
- **DM calls** — 1:1 and group DMs ring their members.
- Rooms starting ad-hoc calls elsewhere are possible in Matrix and deliberately
  not part of this design.
- **Media** — mic, camera and screen share. Everyone can watch a share;
  only desktop can send one (iOS would need a ReplayKit broadcast extension,
  so mobile does not offer it rather than fake it).
- **No chat in voice channels** for now. The room has a timeline; we do not
  show it.
- A **minimal Home** exists only as far as DM calls need: a Home item in the
  space rail, a list of DMs, and a DM conversation. The full Home design
  (favourites, rooms in no space) remains its own wave-2 feature.

## Protocol mapping

| UI | Matrix / LiveKit |
|---|---|
| Being in a call | MatrixRTC membership state (`org.matrix.msc3401.call.member`) in the room; media over LiveKit via Element Call's stack |
| Live avatars under a voice channel or DM | The same membership state, readable without joining |
| A DM ringing | MSC4075 `m.rtc.notification` with `notification_type: "ring"` alongside the caller's join |
| Declining | MatrixRTC decline (MSC4310) — to confirm against matrix-dart-sdk |
| Ring stops when answered on another device | Your own membership appears on all your devices |
| 🔒 | Element Call per-participant media E2EE, keys over to-device |
| iOS incoming call | PushKit VoIP push → CallKit (system UI, not ours) |

**Voice channels never ring and never send an `m.rtc.notification`.** The only
sign of life is occupant avatars under the channel.

## 1. The model

**One call at a time.** Joining a voice channel, starting a DM call, or
accepting a ring while in a call silently drops the current one. No prompt:
picking another call is already understood to mean leaving this one.

The session holds:

- **target** — a voice channel or a DM
- **phase** — `ringing` (DMs only) → `connecting` → `live` → `reconnecting`,
  or `failed` ("couldn't connect")
- **local state** — mic, deafen (implies mute), camera, screen share (desktop),
  audio route (mobile)
- **participants** — each with mic, camera, screen, speaking and deafened
  flags; DM invitees also carry a ring state: `ringing`, `joined`,
  `declined`, `noAnswer`
- **pinned** — the tile in the spotlight, if any

**One call view, three containers:**

| Container | When |
|---|---|
| Voice channel page | Replaces the channel view. Not connected → lobby (see below) |
| DM call panel | Docked at the top of a DM, compact or expanded; resizable on desktop |
| Connected-call bar | You are in a call and looking elsewhere. Reads the channel and space, or "call with Mika" / "call · Mika, Jun +1" for DMs. Tapping it returns to the call's own container |

**Opening a voice channel.** Desktop: one click connects and shows the live
call. Mobile: a tap opens the lobby, and **join voice** connects. Tapping a
voice channel you have not joined joins the room without connecting, on both
platforms, and opens its lobby. Disconnecting lives on the bar and the call
controls, never on tapping the channel.

## 2. The call view

**Tiles.** Camera off: the identity-coloured avatar, large and centred.
Camera on: video (the mock draws a tinted placeholder). Name bottom-left in
name colour — power level in voice channels, default in DMs. Speaking: an
`online` green ring. Muted and deafened badges beside the name. Your own
camera preview is mirrored and carries flip-camera on mobile. Alone in a call:
just your tile, no caption.

**Grid** by count and width. Mobile: 1 → full, 2 → stacked, 3–4 → 2×2,
5+ → two columns, scrolling. Desktop: up to 3–4 columns by pane width.

**Spotlight.** A screen share takes the spotlight automatically, everyone else
in a filmstrip (bottom on mobile, right on wide desktop). Two shares: the
newest is spotlit. Pinning any tile overrides; unpinning returns to the grid
or the share.

**Tile actions.** Mobile: tap to pin or unpin; long press opens a sheet with
pin, a volume slider and view profile. Desktop: hover shows a pin button,
right-click opens the same actions as a menu.

**Controls.**

- Mobile bottom bar: mic, camera, audio route, deafen, leave (accent red).
  Top bar: a chevron (to navigation for voice, to compact for DMs), name, 🔒,
  participant count.
- Desktop bottom bar: mic ⌄ and camera ⌄ with device menus, share screen,
  deafen, leave. Top bar: name, 🔒, pop-out, fullscreen.
- Desktop shortcuts: ⌘/Ctrl+Shift+M mute, +D deafen, +V camera, named in
  tooltips.

**Lobby.** The same page, not connected: whoever is there, dimmed; your
preview tile with camera off; live mic and camera toggles so you choose your
state before joining; one **join voice** button.

## 3. DM ringing

**Starting.** The DM header has 📞 (camera off) and 🎥 (camera on). Either
opens the panel compact in `ringing`. The caller is already in the call;
"ringing" is presentation.

**Outgoing, 1:1.** Your tile beside theirs, their avatar pulsing, "ringing…";
leave cancels. Answer → `live`. 30 s silence → "no answer" with **call again**
and **close**. Declined → "Mika declined", same actions.

**Outgoing, group.** Each invitee's tile shows its own state: pulsing,
declined (dimmed), no answer (dimmed). The call goes live when anyone joins
and stays live whoever else declines. Nobody answers → the same "no answer"
state.

**Incoming.**

- iOS: CallKit's screen. Answering lands in the DM with the panel expanded.
- Desktop: a card top-right over whatever you are doing — pulsing avatar,
  "mika is calling" (group: "mika is calling · weekend crew"), **accept** and
  **decline**. Clicking the card body opens the DM. Accepting opens the DM with
  the panel compact.
- Android (best-effort): the same card, pinned to the top.

**The ring stops** on accept, decline, the caller cancelling, 30 s, or your
answering on another device.

**DM rows.** Ringing: a pulsing phone glyph in `online` green. Live call:
occupant avatars as voice channels have. A missed call counts as unread.

**DM timeline.** Calls leave compact system lines: "call · 12m" on end,
"missed call", and "no one answered" for an unanswered group call. No call
history screen.

## 4. Platform edges and connection states

**Connection states**, in the call view's top bar and on the connected-call
bar: *connecting…* (tiles dimmed, spinner); *reconnecting…* (`idle` amber,
tiles dimmed); *couldn't connect* (ends with **retry** and **close**);
*ringing…* for an outgoing DM call. 🔒 only while media encryption is active,
explained on hover (desktop) or tap (mobile).

**Permissions.** OS-denied mic or camera: the button shows a slash and is
disabled; tooltip (desktop) or tap-for-sheet (mobile) says it is blocked in
system settings.

**Screen share (desktop).** **Share screen** opens a menu of screens and
windows. While sharing, a slim accent strip: "you're sharing · stop". One of
the few red moments: broadcasting must never go unnoticed.

**Fullscreen (desktop).** The call view fills the window, hiding the rail and
channel list; Esc or the button returns.

**Pop-out (desktop).** A "coming later" toast, like the emoji picker's "+".

**iOS backgrounding** (spec only; the mock cannot show it). CallKit's green
status-bar pill and lock-screen controls, with CallKit mute synced to ours.
Picture-in-picture of the spotlight, or the active speaker, while any camera
or screen is on. Voice-only calls keep running.

**Unchanged.** The account panel's mute and deafen still drive the call.
Leaving a voice channel's room still disconnects.

**Mock debug.** A debug button on the account panel (debug builds only) opens
simulate incoming call (1:1 and group), toggle reconnecting, fail the next
connection, toggle encryption, block the mic or camera, and have someone share
their screen.
