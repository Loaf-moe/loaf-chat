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

**Platforms.** iOS is primary — correctness is judged there. Android is
best-effort in v1: it gets whatever works for free and no dedicated native glue
(no FCM, no Android call UI) until someone needs it. Desktop is out of scope for
v1 but must not be designed out; layout and platform abstractions keep the door
open.

**Distribution.** Paid Apple Developer account, TestFlight. App Store is not a
v1 goal.

**Explicit non-goals for v1.** Threads, message search, moderation and roles UI,
web, and any Android-specific native work. Community management depth and
threads are v2; each gets its own spec.

## Stack

| Package | Role |
| --- | --- |
| `matrix` ^12.0.1 | Sync, rooms, E2EE, MatrixRTC signalling |
| `flutter_vodozemac` | Olm/Megolm primitives (Rust, consumed prebuilt) |
| `livekit_client` | SFU media for voice channels |
| `flutter_callkit_incoming` | iOS CallKit and PushKit ringing (MSC4075) |
| `go_router` | Routing, `matrix.to` deep links, desktop later |
| `provider` | Hands out the one `Client` instance; nothing more |

**Why matrix-dart-sdk and not a WebView around Element Call.** As of v12.0.1
(2026-09-02) the SDK ships LiveKit group calls, E2EE key management, MSC4075
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
space. Every Matrix client needs this escape hatch.

**Voice channels are identified by room type.** A room is a voice channel when
its room type marks it as one (Element's video rooms use `m.call`, unstable
`org.matrix.msc3417.call`). Live occupancy comes from MatrixRTC membership state
events, which arrive over normal sync — so participant avatars update without
joining the call. The exact identifiers are confirmed against matrix-dart-sdk
during implementation; the IA depends only on the marker existing.

**The connected-call bar** sits above the composer once you join a voice
channel: connected state, mute, disconnect, tap to expand to the full call UI.
It survives navigating to other channels and other spaces. Without it, voice
collapses back into a modal call.

**Rooms in multiple spaces appear in each.** No canonical-parent logic and no
deduplication. Matrix permits it; pretending otherwise creates bugs.

**Desktop, later.** The loaf.moe design system's `ui_kits/app/` already
specifies the desktop form of this IA: a 76px navy-900 spaces rail, a 268px
cream sidebar, and a module view. Mobile collapses those columns into drawers,
so desktop is an expansion of the same structure rather than a second design.

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

**The member list** mirrors the navigation drawer: a right drawer on phones, a
column toggled by the members button on wide layouts. Admins get their own
section at the top; moderators stay with members and stand out by colour, which
keeps this short of the roles UI deferred to v2. Online people sort first, and
offline people are dimmed rather than hidden.

## Process

The UI is designed as Flutter mockups before any functionality is implemented —
hardcoded data, no SDK, no network. The mockups are not throwaway: they are the
real widget tree with a fake source, so wiring the SDK later fills the same
constructors.

Mockups proceed in waves so feel can be judged early:

1. **The premise** — app shell, channel view, voice channels with participants,
   connected-call bar.
2. **Depth** — expanded call UI, member list, message long-press actions,
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
- **iOS builds require the Mac.** Push notifications, CallKit, and background
  modes cannot be tested on Linux at all. Schedule that work around Mac access
  rather than discovering the gap late.
- **matrix-dart-sdk moves fast.** It reached v12 in roughly two years and its
  major versions carry breaking changes. Keeping all SDK contact inside
  `matrix/` limits the blast radius of an upgrade.
