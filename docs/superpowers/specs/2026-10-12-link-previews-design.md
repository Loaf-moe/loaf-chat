# Loaf Chat — Link previews

A link in a message is tappable text and nothing more. This spec puts a
preview card under a message for its first web link: the page's title,
description and picture, as the homeserver reports them. The homeserver
fetches the page, so the linked site sees the homeserver's address and never
the device's.

It is not a phase of `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`.
It builds on the media seam of `2026-09-30-media-design.md` and shares that
spec's "external content" setting.

## Scope

**In:**

- A preview card under a text message for its first web link.
- Title, description and picture, with the link's host as the card's top
  line.
- Rooms that are not encrypted, with "external content" on.
- No request to a homeserver that says it previews nothing.
- The mock backend serves sample previews, so tests and previews draw the
  card.

**Out:**

| Deferred | Why |
|---|---|
| Previews in encrypted rooms | The request hands the homeserver a link it cannot otherwise read |
| More than one card per message | One card of fixed height keeps a row's growth to one known step |
| Fetching the page from the device | It tells the linked site the device's address, and needs an HTML parser the app does not carry |
| A preview while composing | The composer has no row to draw one in |
| Keeping previews across launches | The homeserver caches its own for 24 hours |
| A per-room switch | The app has no per-room local settings |
| Playing a previewed video in the card | The card opens the link; `og:video` is not read |

## Findings (checked 2026-10-12)

Sources: `matrix` 13.0.0 in the pub cache, tuwunel at `f473d9a4`, and this
repository at `916578d`.

**The SDK**

- `Client.getUrlPreview(Uri url, {int? ts})` asks
  `GET /_matrix/client/v1/media/preview_url` when
  `authenticatedMediaSupported()` is true, and the deprecated
  `GET /_matrix/media/v3/preview_url` otherwise. Both send the bearer token.
- A status other than 200 throws `MatrixException`.
- `PreviewForUrl` types two fields: `ogImage` (`og:image`, a `Uri`) and
  `matrixImageSize` (`matrix:image:size`). Everything else, `og:title` and
  `og:description` included, is untyped in `additionalProperties`.
- `PreviewForUrl.fromJson` casts `matrix:image:size` to `int` and `og:image`
  to `String`, and parses the latter with `Uri.parse`: a reply with either
  in another shape throws.
- The SDK caches no preview, and nothing in this repository calls the method.
- `FakeMatrixApi` answers both paths for `url=https://matrix.org&ts=10` only.
- `getCapabilities()` asks `GET /_matrix/client/v3/capabilities` afresh on
  every call. A capability the SDK has no type for is in
  `Capabilities.additionalProperties`.

**tuwunel**

- Previews are off until an allowlist names something. With
  `url_preview_domain_contains_allowlist`,
  `url_preview_domain_explicit_allowlist` and
  `url_preview_url_contains_allowlist` all empty, which is the default
  (`src/core/config/mod.rs`), every request is refused.
- A link the allowlists do not cover is refused with `M_FORBIDDEN`; a page
  the server could not fetch is `M_UNKNOWN`
  (`src/api/client/media.rs`, `get_media_preview_route`).
- A page whose tags the server could not find answers 200 with an empty
  object (`docs/media/url-previews.md`).
- The reply carries `og:title`, `og:description`, `og:image`,
  `matrix:image:size`, `og:image:width`, `og:image:height`, the `og:video`
  and `og:audio` fields, `og:type` and `og:url`
  (`src/service/media/preview.rs`, `UrlPreviewData`). It carries no
  `og:site_name`.
- `og:image` is an `mxc://` URI on the homeserver, never the other site's
  address.
- The server caches a preview, an empty one included, for
  `url_preview_cache_ttl`, 24 hours by default.
- `/capabilities` carries `io.element.msc4452.preview_url` as
  `{"enabled": bool}`, false while every allowlist is empty
  (`src/api/client/capabilities.rs`).

**This repository**

- `linkedMediaIn` (`lib/matrix/matrix_media.dart`) already turns a link to a
  picture or video into the message's media, and returns null when "external
  content" is off or the room is encrypted.
- `MatrixTimeline` listens to the setting, and maps every event to its row
  afresh on each change.
- Links are found by `linkify`, `safeLink` and the anchor handling in
  `lib/ui/channel/message_markup.dart`; a link lives on `Run.link`. No
  function returns a message's links.
- `parseMessage` keeps the blocks of the 512 texts last read.
- `mentionOf` turns a matrix.to link to a user into a mention. A matrix.to
  link to a room or a message stays a link.
- A run inside a spoiler carries `Run.spoiler`, except a bare address that
  `linkify` made a link: that run lost it, and drew unhidden.
- A media row is sized before its picture loads
  (`lib/ui/channel/media_row.dart`). Nothing corrects the scroll offset for
  a row that grows after layout.
- `MxcThumbnail` (`lib/matrix/matrix_avatar_images.dart`) fetches a server
  thumbnail for an `mxc://` URI and keeps it in the SDK's file store.
- `message_text.dart` has a private `_LinkPreview`: the desktop tooltip that
  shows a link's address on hover.

## The seam

### `Message.previewLink`

`ui.Message` gains `Uri? previewLink`: the link this message offers a
preview of, or null. The backend that made the message decides; the UI
draws a card for a link it is given and looks for none itself.

`firstWebLink(List<Block> blocks)` in `message_markup.dart` returns the
first `Run.link` whose scheme is `http` or `https`, whose host is not
`matrix.to`, and which is not inside a spoiler, or null. A mention carries
no link, and neither does code. `linkify` keeps `Run.spoiler` on the links
it makes.

The mock `TimelineController` sets `previewLink` with `firstWebLink` on the
text messages it starts with, when a message is sent and when it is edited.

### `LinkPreviews`

In `lib/ui/model/link_previews.dart`, provided through a scope like
`MediaSource`.

```dart
abstract interface class LinkPreviews {
  /// What is known of [link]. Asked of the backend once, on first call, and
  /// shared by every row showing the link.
  ValueListenable<LinkPreviewState> of(Uri link);
}

sealed class LinkPreviewState {}

class LinkPreviewLoading extends LinkPreviewState {}

/// The backend has nothing to draw for the link.
class LinkPreviewNone extends LinkPreviewState {}

class LinkPreviewReady extends LinkPreviewState {
  final LinkPreview preview;
}

class LinkPreview {
  final String? title;
  final String? description;
  final ImageProvider? image;
}
```

- A `LinkPreview` has a title, a description or an image. A reply with none
  of the three is `LinkPreviewNone`.
- A title or description is trimmed; an empty one is null.
- `NoLinkPreviews` answers `LinkPreviewNone` for every link, and is what a
  widget gets without a scope.
- `LinkPreviewsScope` is an `InheritedWidget` shaped like `MediaSourceScope`,
  set beside it in `lib/ui/shell/app_shell.dart` from `Rooms.linkPreviews`.
- `MockLinkPreviews` (`lib/ui/mock/`) answers from a fixed table.

The UI never sees an mxc or an OpenGraph key.

## Which messages offer a preview

`MatrixTimeline` sets `previewLink` when all of these hold:

- "external content" is on;
- the room is not encrypted;
- the message is `m.text`, `m.notice` or `m.emote`;
- the server has it (status sent);
- it has no media, attached or linked;
- it is not the quote inside a reply.

The link is `firstWebLink(parseMessage(formatted:, body:))` over the
event's own words, as last edited, once the server has the edit. An emote's
row starts with its author's name; the name is not searched, so it cannot
choose what is previewed. `MatrixTimeline` remembers each message's link by
the event the row draws: a message is parsed for its link once, and again
after an edit.

## Fetching

`MatrixLinkPreviews` (`lib/matrix/matrix_link_previews.dart`) implements
`LinkPreviews` over `Client.getUrlPreview(link)`, with no `ts`.

- **Whether the server previews at all** is asked once, with
  `getCapabilities()`, before the first preview request. A server whose
  `io.element.msc4452.preview_url` is `{"enabled": false}` is asked for no
  preview: every link is `LinkPreviewNone` for the session. A server that
  does not carry the capability, carries it in another shape, or fails to
  answer is asked for previews as usual.
- Links asked about before that answer are `LinkPreviewLoading` until it
  comes.
- One request per link. Rows that ask while it runs share it.
- Results are kept in memory for the session. Sign-out drops them with the
  rooms, and an answer that arrives afterwards changes nothing.

| Outcome | State | Kept |
|---|---|---|
| The server says it previews nothing | `LinkPreviewNone`, with no request | for the session |
| 200 with a title, a description or an image | `LinkPreviewReady` | for the session |
| 200 with none of them | `LinkPreviewNone` | for the session |
| 200 whose fields are of the wrong type | `LinkPreviewNone` | for the session |
| The server refuses (any `MatrixException` other than `M_LIMIT_EXCEEDED`, `M_UNKNOWN_TOKEN` and a server error among them) | `LinkPreviewNone` | for the session |
| `M_LIMIT_EXCEEDED`, no answer (timeout, offline), an answer that is not JSON or not the homeserver's (a proxy's page), or a picture that is not an address | `LinkPreviewNone` | for one minute; the first ask after that requests again |

**Reading the reply**

- `og:title` and `og:description` come from `additionalProperties`, and count
  only when they are strings.
- `ogImage` counts only when its scheme is `mxc`. It becomes
  `MxcThumbnail(client, mxc, 320)`.

## On screen

`LinkPreviewCard` (`lib/ui/channel/link_preview_card.dart`) sits in the
message's column after the text and before the reactions, `LoafSpace.x2`
below the text.

- **Loading:** nothing for the first 300 ms, so a link the server refuses at
  once draws nothing. After that, one line: "loading preview…" in
  `loafBody(12, 400)` `textMuted`, with no box and no fill.
- **Ready:** a card 88 high, up to 400 wide on a computer and the column's
  width on a phone, in place of the line. `card` fill, `border`,
  `LoafRadius.lg`. A picture 88 square fills the left edge when there is
  one. Beside it, each ellipsised: the link's host in `loafBody(12, 400)`
  `textMuted`, the title in `loafBody(14, 600)` `textStrong` on one line,
  the description in `loafBody(12, 400)` `textMuted` on two.
- **None:** nothing. A link already known to have nothing draws no line.
- **Opening:** a tap opens the link through `openMessageLink`. On a computer
  a clicked card takes the focus ring a media row has, and Enter or Space
  opens it again.
- **A picture that fails to load:** the card stays and the text takes its
  place.

A row grows by the card when its preview arrives. A refusal slower than
300 ms takes one line away again. On a server that previews nothing, the
rows drawn before its capabilities arrive show at most that line.

## Settings

No new setting. "external content" covers previews, and its line reads:

> show pictures and video hosted on other sites, and previews of links.
> pictures and video come from those sites, which tells them your address;
> previews come from your homeserver. never used in encrypted rooms.

## Errors

A preview that cannot be had is no card: no toast and no retry control. The
link in the text still opens.

## Testing

Existing tests pass unchanged, apart from the two `_FakeRooms`
(`test/app_shell_rooms_test.dart`, `test/space_actions_test.dart`), which
gain `linkPreviews`.

- **`firstWebLink`** (`test/message_markup_test.dart`): a bare link, an
  anchor, the first of several, a mention, a matrix.to room link, a link in
  code, a link in a spoiler, `mailto:`, no link.
- **The mock** (`test/timeline_controller_test.dart`): a sent message with a
  link offers it; an edit that changes the link changes it; an edit that
  removes the link removes it.
- **Mapping** (`test/matrix/matrix_timeline_test.dart`), over
  `FakeMatrixApi`: `previewLink` for a text message with a link; null in an
  encrypted room, with the setting off, for a message with media, for a link
  that became media, for a sending message and for a quote; the setting
  changing redraws the rows; an edit changing the link, an edit on its way
  not yet changing it, and a deleted edit giving the first link back; an
  emote whose author's name holds a link.
- **Fetching** (`test/matrix/matrix_link_previews_test.dart`), over a
  `FakeMatrixApi` subclass, with the clock passed in:
  - a full reply; a title that is not a string; an image that is not `mxc`;
    an empty reply; a reply whose `matrix:image:size` is not a number;
  - `M_FORBIDDEN` kept and not asked again;
  - a timeout, a request that cannot be sent, `M_LIMIT_EXCEEDED`, a proxy's
    page with either status and a picture that is not an address each not
    asked again within a minute, and asked again after it;
  - two askers sharing one request, at first and after the minute;
  - the legacy path on a server without authenticated media;
  - a server whose capability is disabled asked for no preview, with links
    asked about early ending as none;
  - the capability absent, misshapen or unanswered leaving previews asked
    for;
  - capabilities asked once however many links are shown;
  - an answer after the rooms are disposed changing nothing.
- **The card** (`test/link_preview_card_test.dart`): nothing drawn before
  300 ms; the line after it; the card at 88 high when ready; nothing drawn
  for none; a tap opening the link; the layout without a picture; a picture
  that fails leaving the card; the widths on a computer and a phone; large
  text staying inside the card; a row whose link changes; the focus ring
  and Enter on a computer.
- **The row** (`test/message_group_tile_test.dart`): the card between the
  text and the reactions; no card without `previewLink`; a file with a link
  drawing both.
- **Spoilers** (`test/message_text_test.dart`): a link inside a spoiler
  opening only once shown.

**By hand on loaf.moe:** a link the allowlist covers; one it does not; a
link in an encrypted room; "external content" switched off with a card on
screen; every allowlist emptied, after which a relaunch asks for no
preview.

## Order

1. The seam, the card, the mock, `MatrixLinkPreviews`, the mapping in
   `MatrixTimeline` and the setting's line, as one change.
2. Checks by hand on loaf.moe.
