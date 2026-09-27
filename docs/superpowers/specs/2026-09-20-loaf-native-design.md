# Loaf Native — Design

Date: 2026-09-20
Status: approved (stack, information architecture, visual language). UI screens
are designed separately as Flutter mockups before implementation begins.

## Purpose

A Flutter Matrix client for loaf.moe that combines three things no existing
client puts together:

- **Cinny's design language** — which loaf-chat (a Cinny fork) already ships
  and which the loaf.moe brand extends.
- **FluffyChat's native feel** — a real mobile app, not a web app in a shell.
- **MatrixRTC / Element Call voice channels** — which FluffyChat gained in
  2.10 but which its group-chat shape does not foreground.

The organising idea is that a space is a *server*, not a folder. Loaf Native is
shaped like Discord: persistent spaces, channels within them, always-on voice
channels you join and linger in. loaf-chat remains the web and desktop client
and is expected to retire once Loaf Native covers desktop.

## Scope

**v1 — the daily-drivable milestone.** The client the author replaces their
phone client with:

- Login: `.well-known` server discovery, SSO and password.
- Navigation: space rail, channel list, channel view.
- Messaging: send and receive text, images, files; reactions; replies.
- Encryption: E2EE with cross-signing and key backup.
- Notifications: APNs push via self-hosted Sygnal.
- Voice: join MatrixRTC voice channels, with a persistent connected-call bar.

**Platforms.** iOS is primary — correctness is judged there, and most design
attention goes to mobile. Desktop (macOS and Linux) is built alongside it rather
than deferred: the early mockups showed Flutter makes it close to free, so every
feature ships with its desktop form (pointer and keyboard idioms, wide layouts)
at the same time as its mobile one. Android is best-effort in v1: it gets
whatever works for free and no dedicated native glue (no FCM, no Android call
UI) until someone needs it. Where a platform offers a native mechanism, that
is the default; portable workarounds are only for platforms without one.

**Distribution.** Paid Apple Developer account, TestFlight. App Store is not a
v1 goal.

**Explicit non-goals for v1.** Threads, message search, moderation and roles UI,
web, and any Android-specific native work. Community management depth and
threads are v2; each gets its own spec.

## Stack

| Package | Role |
| --- | --- |
| `matrix` ^13.0.0 | Sync, rooms, E2EE, MatrixRTC signalling |
| `flutter_vodozemac` | Olm/Megolm primitives (Rust, consumed prebuilt) |
| `livekit_client` | SFU media for voice channels |
| `flutter_callkit_incoming` | iOS CallKit and PushKit ringing (MSC4075) |
| `go_router` | Routing, `matrix.to` deep links, desktop later |
| `provider` | Hands out the one `Client` instance; nothing more |

**Why matrix-dart-sdk and not a WebView around Element Call.** As of v13.0.0
(2026-09-22) the SDK ships LiveKit group calls, E2EE key management, MSC4075
ringing, and delayed-leave heartbeats. FluffyChat 2.10 proves the stack
interoperates with Element and Cinny. Native calls give native CallKit and
picture-in-picture, which a WebView cannot. The existing `element-call` fork
stays where it is, serving loaf-chat.

**Rust exposure is one prebuilt shard.** Only vodozemac is Rust, reached through
flutter_rust_bridge. Everything above the crypto primitives is pure Dart. Use
the **Swift Package Manager** integration on iOS so the build consumes a
prebuilt `flutter_vodozemac.xcframework` and needs no Rust toolchain; the
CocoaPods path compiles from source via cargokit and is slower for no benefit.

**State management: the SDK is the store.** `Client` already holds rooms,
timelines, and sync state, and exposes them as streams. The UI binds to
`client.onSync` and `Room` streams directly. There is no second model layer — a
duplicate room list is a second thing to get out of sync. `provider` exists only
to pass the `Client` down the tree.

**Layering — three directories, not a framework.**

- `matrix/` — the only code that imports `package:matrix`. Thin functions over
  `Client`: send a message, join a space, start a call.
- `ui/` — screens and widgets. Reads streams, calls into `matrix/`.
- `platform/` — native glue: push registration, CallKit, notifications,
  background modes. iOS-specific behaviour is quarantined here so the rest stays
  portable to desktop.

**Homeserver.** loaf.moe (tuwunel, with LiveKit and lk-jwt-service already
deployed) is the development target, but nothing hardcodes it. Server discovery
runs through `.well-known` like any client.

## Information architecture

The phone layout is Discord's, because it is the solved version of this problem.
The main surface is the channel you are reading; navigation is a left drawer and
the member list is a right drawer.

**Left drawer, two panes side by side.**

- **Space rail** — a narrow strip of space avatars. `Home` pinned at the top,
  then spaces, each carrying unread dots and mention badges.
- **Channel list** — the selected space's rooms. Subspaces render as
  collapsible categories; Matrix has subspaces and Discord does not, and
  categories are the natural mapping. Text and voice channels share one list.
  Voice channels show live participant avatars nested underneath, which is what
  makes voice read as always-on rather than call-shaped.
- **User chip** pinned to the bottom of the channel list: avatar, display name,
  quick mute, settings.

**`Home` is a pseudo-space** holding DMs, favourites, and rooms belonging to no
space. Every Matrix client needs this escape hatch. The loaf mark at the top of
the rail opens it. Its list runs in sections, each collapsible and hidden when
empty, and each room appears in exactly one:

| Section | Matrix | Order |
|---|---|---|
| Invites | rooms in the `invite` state | as received |
| Favourites | `m.favourite` room tag | yours, from the tag's `order` |
| Direct messages | rooms listed in `m.direct` account data | most recent activity |
| Rooms | joined rooms that are no joined space's child (computed) | alphabetical |
| Low priority | `m.lowpriority` room tag | alphabetical, collapsed |

Favourite beats low priority, and both beat DM or room. Tags are set from a
Home row's actions (long press, right-click) and only there: a space channel
tagged elsewhere keeps its one place, in its space. Favourites reorder by drag;
on a phone, a long press that moves drags and one that lets go in place opens
the actions. The server's admin room (tuwunel's `#admins`, where `!admin`
commands go to the server bot) is an ordinary room in no space, so it lives
under Rooms. Server notices (`m.server_notice`) would too.

An invite opens a preview, never the room: name, avatar, who invited you, and
the topic and member count when the server's preview offers them, with accept
and decline. Accepting a DM or room opens it in its section; accepting a space
adds it to the rail. The Home badge counts DM unreads, room mentions and
invites.

**Starting a DM never makes a duplicate.** The "+" on the direct messages
heading opens a picker (a sheet on a phone, a dialog on a computer) that
searches names and ids (`/user_directory/search`, or a typed full id). Each
person is listed with their existing 1:1 rooms right under them. The button
opens rather than creates whenever it can: the newest 1:1 room with one person,
or a group DM with exactly the people picked. Only then does it create one —
`createRoom` with `is_direct` and the `trusted_private_chat` preset, the people
invited, and the room added to `m.direct` — which opens at once with a
"waiting for … to join" line until they do.

Duplicates made elsewhere (another client, or both people starting at once)
fold into one row per person: the newest room opens, the row counts every
room's unreads, and the rest are under "Older conversations" in its menu.
Group DMs are not merged. Nothing is ever left automatically; leaving loses a
room's history on this device.

**Voice channels are identified by room type.** A room is a voice channel when
its room type marks it as one (Element's video rooms use `m.call`, unstable
`org.matrix.msc3417.call`). Live occupancy comes from MatrixRTC membership state
events, which arrive over normal sync — so participant avatars update without
joining the call. The exact identifiers are confirmed against matrix-dart-sdk
during implementation; the IA depends only on the marker existing.

**The connected-call bar** sits above the composer once you join a voice
channel: connected state, mute, disconnect, tap to expand to the full call UI.
It survives navigating to other channels and other spaces. Without it, voice
collapses back into a modal call. The expanded call UI, DM calls and ringing are
designed in `2026-09-24-calls-design.md`.

**Joining a space shows you all of it.** In Matrix, joining a space joins only
the space room; its channels are listed by `m.space.child` events and read
through `/hierarchy`, and other clients leave you to go and find them. Here:

- **Categories are subspaces, joined silently.** Matrix has no category
  concept, so a category is a child space. Joining a space also joins its
  category subspaces, because a subspace's own changes — a channel added to
  it — only reach you over sync if you are a member. They are plumbing; you
  never meet them as rooms.
- **Suggested channels join automatically.** Children the space's admins mark
  `suggested` are joined along with the space, so it is populated from the
  first second.
- **Everything else you could join is listed, tagged.** Channels you are not in
  sit at the bottom of their own category, in muted text with a *join* tag;
  one tap joins them. A text channel then opens; a voice channel does not
  connect, since membership and being in the call are separate steps. Only
  channels joinable in one tap (join rule `public` or `restricted` to the
  space) are listed; invite-only rooms you are not in stay out of sight.
  Channels added later appear the same way.

**Adding a space.** The dashed "+" at the foot of the rail opens one panel (a
sheet on a phone, a dialog on a computer) with three paths. Whatever would be
joined is previewed first — name, avatar, topic, member count and its first
channels — from `/hierarchy` (MSC2946):

- **Join with a link.** An alias with or without its `#`, a room id, or a
  `matrix.to` link (encoded or not, `?via=` hints dropped) is resolved through
  `/directory/room` and previewed. An address with nothing behind it says so;
  an invite-only space says to ask someone inside, with no join button. Knock
  (`knock` join rule) is treated as invite-only for now.
- **Explore public spaces.** `/publicRooms` with `room_types: ["m.space"]`,
  searchable, for loaf.moe by default and switchable to matrix.org or any
  server by name. Spaces you are in are marked and open instead.
- **Create a space.** A name; the avatar is its initials on a colour taken
  from the name. It is created as a space room (`creation_content.type:
  m.space`) with `#general` and a voice channel called `hangout` as children
  (`m.space.child` / `m.space.parent`), both `restricted` to the space. No
  categories; adding channels afterwards is space settings, not this.

Joining a space you hold an invite to answers the invite.
- **Edges.** Channels directly under the space, in no subspace, go at the top
  uncategorised. Subspaces nested deeper than one level flatten into their
  top-level category. A room that is a child of two subspaces appears in both.

**Channel actions** — *Mark as read* (when there is something unread), *Mute* or
*Unmute*, and *Leave* — open the same way message actions do: long press on
mobile, right-click on desktop. Unjoined channels have none; joining is their
one action and a tap does it.

- **Mute is a single toggle with no expiry.** It maps to a mentions-only push
  rule, so it syncs to every device, and mentions still reach you. A muted
  channel loses its bold unread styling and shows a muted-bell mark; its
  mention badge stays. Matrix has no expiring push rules, so there are no timed
  mutes — they would depend on some client being awake to lift them.
- **Leaving an open channel does not ask**: rejoining is one tap, and the
  channel returns to its tagged place at the bottom of its category.
  **Leaving an invite-only channel asks first**, since coming back needs a new
  invite, and it then disappears from the list. Leaving the channel you are
  reading moves you to the space's first joined text channel; leaving a voice
  channel you are connected to disconnects you.

**Rooms in multiple spaces appear in each.** No canonical-parent logic and no
deduplication. Matrix permits it; pretending otherwise creates bugs.

**Desktop, alongside.** The loaf.moe design system's `ui_kits/app/` already
specifies the desktop form of this IA: a 76px navy-900 spaces rail, a 268px
cream sidebar, and a module view. Mobile collapses those columns into drawers,
so desktop is an expansion of the same structure rather than a second design.

## Sign-in and verification

Signing in never blocks on verification. You land in the app, and an
unverified or identity-less session is carried by a rail notice with no
dismiss, as ignoring it silently loses messages.

### Discovery

The server picker takes a name (`loaf.moe`), a URL (`https://matrix.loaf.moe`)
or a full id (`@chris:loaf.moe`, of which only the domain is kept). Typing a
full id into the username field re-points the server line after a short
debounce, with its own "looking for…".

| Step | Matrix |
|---|---|
| Find the homeserver | `GET https://<name>/.well-known/matrix/client` → `m.homeserver.base_url`; no file → try the name itself |
| Confirm it | `GET /_matrix/client/versions` |
| Learn the ways in | `GET /_matrix/client/v3/login` → `m.login.password`, `m.login.sso` with `identity_providers[]` |

The server line always shows the name you typed, never the delegated base URL.
Three failures are told apart, since the third is a self-hoster's
misconfiguration: nothing answered at X; X isn't a matrix server; X points to
Y, which didn't answer.

### The sign-in screen

One identity provider is "continue with <name>". Several are equal stacked
buttons with the provider's icon (letter fallback): the server's order is not
a preference. The password form stays behind a link, offered only where the
server advertises `m.login.password`.

**SSO** (`/login/sso/redirect/{idpId}?redirectUrl=…`, answered with a
`loginToken` exchanged via `m.login.token`) splits by platform. On iOS and
macOS it runs in the system's `ASWebAuthenticationSession` sign-in window,
which closes itself and hands back to the app; the screen says "signing
in…" meanwhile. Only where the platform has no such window (Linux, Windows)
does the real browser open: the screen becomes "finish in your browser",
with open it again and cancel, and when the browser hands back, the app
comes to the front and the tab says it can be closed. The next-generation
OAuth 2.0 API (MSC3861, advertised at `/auth_metadata`) looks the same: one
"continue with" button.

**Password** (`m.id.user`) shows the button busy while it works. `M_FORBIDDEN`
is "that username and password didn't match" under the fields;
`M_LIMIT_EXCEEDED` counts its `retry_after_ms` down on the disabled button.
Fields carry autofill hints so the Keychain and password managers fill them;
Enter submits on a computer.

**Soft logout** (`soft_logout: true` on a rejected token) keeps the device's
keys, so the screen is locked to that account: avatar, "welcome back", "sign in
again as @chris:loaf.moe" with that server's controls and no server line. A
quiet "sign out instead" confirms first, because it takes this device's keys
with it.

### Verifying a session

A new session is trusted once the account's cross-signing self-signing key
signs it. The verify notice opens a panel (sheet on a phone, dialog on a
computer) offering, in order:

| Route | Matrix |
|---|---|
| Another device | `m.key.verification.request` to your devices → SAS with 7 emoji → secrets arrive by `m.secret.request` |
| Recovery key or passphrase | unlocks secret storage (SSSS), yielding the cross-signing keys and the key backup key |
| Reset identity | new cross-signing keys, uploaded behind user-interactive auth |

Another device is offered only when other sessions exist, listed by name
beneath it. Its steps: waiting for acceptance; the 7 emoji with their names in
a 4 + 3 grid, "they match" or "they don't match"; waiting for the other side;
done. A mismatch or timeout says nothing was trusted and offers try again.

The recovery field takes a key or a passphrase made elsewhere, hidden with a
reveal toggle. A key that unlocks nothing says so. One that works restores
history from key backup with a count ("restored 1,204 of 3,380 keys") that
carries on if the panel closes.

Reset explains its cost first: contacts see "identity changed", and history
unreachable now stays unreadable. Its button spends the accent red. It then
re-authenticates (password, or SSO through the same browser wait) and ends in
setting up recovery, because a reset is a fresh identity.

Verified, the panel closes, the notice goes and a toast confirms.

**The other end.** A verified session receiving a request pops the same panel
at once: "new sign-in: is this you?", the device's name and when it signed in.
Yes runs the same emoji widget both ends share. "That's not me" cancels and
suggests signing the device out in settings. Closing the panel ignores the
request, which times out as the protocol specifies (10 minutes).

**Setting up recovery.** An account with no cross-signing identity (a first
sign-in through Kanidm) gets a "set up recovery" notice instead, also without
dismiss. Its panel creates the identity and a recovery key, shown in monospace
as 12 groups of four, selectable on a computer, with copy and save as file.
"I've saved it" enables only after one of them: losing this key is the one
mistake nothing recovers. No passphrase creation and no read-back quiz.

### The mockup

A `MockSession` in `lib/ui/mock/` holds the fake account (signed out, soft
logged out, signed in) and device trust (no identity, unverified, verified),
and plays each flow out on timers. The app shows sign-in or the shell from it.
Debug levers: sign out, expire session, fresh account, new sign-in from another
device; "fail the next connection" also fails the next sign-in or verification.
Every face renders from a plain state value, so tests pin each one directly.

## Visual language

The loaf.moe design system is the source of truth. Its tokens port once into a
Flutter `ThemeData` plus a `LoafTokens` theme extension:

- **Colour** — deep navy `#003049` ink, warm red `#d62828` used sparingly (send
  button, unread badges, active channel), toasty cream `#FFF7ED` surfaces.
- **Type** — Lora for display, Outfit for UI, IBM Plex Mono for code. Fonts are
  bundled rather than fetched, so the app renders correctly offline.
- **Form** — generous corner radii, soft navy-tinted shadows, springy press
  states (`scale .985`).

**Dark theme ships as the default.** The design system defines no dark palette,
but the brand already has a dark surface language: the spaces rail is navy-900.
The dark palette is derived from the navy scale and treated as an extension of
the design system, not a departure from it. The cream palette remains available
and is designed alongside it, so neither is retrofitted.

**Name colour means power level, everywhere.** Wherever a person's name is
drawn — timeline author, reply quote, member list — its colour says what they
can do in the room, and nothing else:

| Role | Power level | Colour |
|---|---|---|
| Admin | ≥ 100 | `accent` |
| Moderator | ≥ 50 | `nameModerator` (a softer step of the accent ramp) |
| Member | below 50 | `textStrong` |

Identity is the avatar's job, not the name's. Matrix has no user-chosen colour —
a profile is a display name and an avatar — so there is nothing for a name
colour to reflect except permissions. Where an avatar has no image, its fallback
background stands in for a colour derived from the MXID, as other clients do;
that colour never reaches a name. Roles stay inside the brand's single warm hue
rather than adding new ones. All name colours resolve through
`LoafTokens.nameColor(role)` (`lib/ui/members/role_colors.dart`), so no widget
picks its own.

**Presence and status.** Tapping your avatar in the account panel opens a
picker — a bottom sheet on mobile, a popover on desktop — with a status message
and four presence choices. Settings edits the same presence; there is one
source of truth. Each maps onto Matrix like so:

| Choice | Others see | Matrix |
|---|---|---|
| Online | green dot | `online` |
| Idle | amber dot | `unavailable`; also set automatically after inactivity, pinned when chosen |
| Do not disturb | red dot with a bar | MSC3026 `busy` where the server supports it, **plus** the account's master push rule switched on, silencing every device; leaving DND switches it off |
| Invisible | offline ring | sync with `set_presence=offline`: connected, but shown offline |

The status message is `status_msg`, free text with no expiry — it stays until
cleared. It shows as a muted line under the name in the member list. Presence
is often disabled on homeservers because it is expensive, so people on servers
without it must read as **unknown**, never as offline. Presence reaches you
through your own homeserver, so there are two cases:

- **Their server shares none** (matrix.org runs this way): that person is
  unknown. No dot, not faded, and sorted between people who are around and
  people who are away.
- **Your server shares none:** nobody's presence arrives and yours goes
  nowhere. Every dot disappears, nobody is faded, and the status picker keeps
  only the status message, saying "this server doesn't share presence".

Absent means absent: a question mark on every avatar would be noise when a
whole server has none.

**The member list** mirrors the navigation drawer: a right drawer on phones, a
column toggled by the members button on wide layouts. Admins get their own
section at the top; moderators stay with members and stand out by colour, which
keeps this short of the roles UI deferred to v2. Online people sort first, and
offline people are dimmed rather than hidden.

**Message actions split by platform, not input device.** The same actions —
quick reactions, reply, copy, and edit or delete on your own messages — are
reached the way each platform expects:

- **Mobile (iOS, Android):** long press, with a haptic, opens a bottom sheet:
  quick reactions within thumb reach, then the action list.
- **Desktop (macOS, Linux, Windows):** no long press at all. Message text stays
  selectable, because selecting part of a message is something people do on a
  computer and losing it is not an acceptable trade. Hovering a message shows a
  small toolbar on its top edge; right-click opens the action menu at the
  pointer, leading with *Copy selection* when text is selected.

**Sending.** On desktop, Enter sends and Shift+Enter starts a new line; on
mobile, Return is a new line and the send button sends. Replying or editing
puts a card above the composer — the mode, who or what it is aimed at, and a
line of the message itself — which Escape (desktop) or its close button backs
out of. Emptying an edit and sending it asks whether to delete the message
instead; saving an edit unchanged is not an edit. Tapping a reaction pill
toggles your own reaction on it, and the trailing + opens the message's
actions with the quick reactions first.

**The emoji picker** holds every Unicode emoji, generated from Unicode's
`emoji-test.txt` by `tool/gen_emoji.dart` into a checked-in table:
fully-qualified forms only, capped at the Emoji version the platforms' fonts
draw (17.0 for now), skin-tone variants left for a later skin tone setting.
Search matches names, whole words first; category tabs switch the grid; a
recents row keeps your latest picks (account data `io.element.recent_emoji`
in the SDK phase, so they follow you across devices). A sheet on a phone —
where the keyboard waits to be asked for — and a popover by the button on a
computer. From the composer's 😊 a pick is inserted at the cursor; from a
message's "more reactions" it is a reaction (`m.reaction`), never a removal.
Custom emoji (image packs, MSC2545) are a later feature.

Deleting someone else's message is moderation and stays out of v1; delete is
offered on your own messages only, and always asks first, because a redaction
cannot be undone.

## Process

The UI is designed as Flutter mockups before any functionality is implemented —
hardcoded data, no SDK, no network. The mockups are not throwaway: they are the
real widget tree with a fake source, so wiring the SDK later fills the same
constructors.

Mockups proceed in waves so feel can be judged early:

1. **The premise** — app shell, channel view, voice channels with participants,
   connected-call bar.
2. **Depth** — expanded call UI and DM calls (see the calls spec), member list, message long-press actions,
   Home/DM list, space browse.
3. **Edges** — login and server discovery, settings, search, media viewer.

Iteration happens on Flutter Linux desktop and widget previews, with periodic
checks on a real iPhone. Builds and TestFlight run from a Mac.

The implementation plan — SDK wiring, push, calls — is written after the UI
settles.

## Known risks

- **Notification bodies in encrypted rooms.** Without an iOS Notification
  Service Extension, push shows sender and room name but not message content,
  because the homeserver cannot decrypt. A Flutter app cannot easily share its
  Dart crypto store with a Swift extension. v1 ships without the NSE; it is
  revisited only if the missing body proves annoying in practice.
- **MatrixRTC discovery is changing.** Element Call 0.24 deprecated
  `.well-known` RTC discovery in favour of MSC4519's `/rtc/transports` endpoint
  and MSC4515's `get_rtc_transports` widget action. The loaf.moe tuwunel
  configuration currently advertises the older `org.matrix.msc4143.rtc_foci`.
  This works today and is a known upgrade.
- **Setting up recovery may need re-authentication.** Uploading the first
  cross-signing keys can require user-interactive auth; MSC3967 exempts the
  first upload, but whether tuwunel implements it is unconfirmed. If not, that
  flow grows the same re-auth step reset has — for an SSO-only account, a
  browser round trip.
- **iOS builds require the Mac.** Push notifications, CallKit, and background
  modes cannot be tested on Linux at all. Schedule that work around Mac access
  rather than discovering the gap late.
- **matrix-dart-sdk moves fast.** It reached v12 in roughly two years and its
  major versions carry breaking changes. Keeping all SDK contact inside
  `matrix/` limits the blast radius of an upgrade.
