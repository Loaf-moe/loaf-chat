# Link Previews Implementation Plan

**Goal:** A message's first web link shows a preview card, fetched by the homeserver, in rooms that are not encrypted.

**Architecture:** The timeline row reads a `LinkPreviews` interface through `LinkPreviewsScope`, as it reads `MediaSource`. `MockLinkPreviews` implements it for tests and previews. `MatrixLinkPreviews` implements it over the SDK's `Client.getUrlPreview`. `MatrixTimeline` decides which messages offer a link, and puts it on `Message.previewLink`.

**Tech Stack:** Flutter 3.47.5 (pinned in `mise.toml`; run every command through `mise exec --`), `matrix` 13.0.0. No new dependency.

**Spec:** `docs/superpowers/specs/2026-10-12-link-previews-design.md`. Read it first; the seam, the outcomes table and the card's layout are there and are not repeated here.

**Not rehearsed.** The task below was not run on a scratch copy first. It is planned in detail when it starts.

## Global Constraints

- `lib/ui/` does not import `package:matrix`.
- Tests use no network: the Matrix side runs against a `FakeMatrixApi` subclass.
- Each test is written before the code it covers.
- No request is made for a link in an encrypted room, with "external content" off, or on a server whose capabilities say it previews nothing.

## Task 1: a link's preview under its message

Commit: `feat(previews): a link's preview shows under its message`

**Files**

- `lib/ui/channel/message_markup.dart`: `firstWebLink`.
- `lib/ui/model/models.dart`: `Message.previewLink`.
- `lib/ui/channel/timeline_controller.dart`: sets `previewLink` on send and on edit.
- New `lib/ui/model/link_previews.dart`: `LinkPreviews`, `LinkPreviewState` and its three cases, `LinkPreview`, `NoLinkPreviews`, `LinkPreviewsScope`.
- New `lib/ui/channel/link_preview_card.dart`: `LinkPreviewCard`.
- `lib/ui/channel/message_group_tile.dart`: the card in `_MessageBody`'s column.
- `lib/ui/rooms/rooms.dart`: `LinkPreviews get linkPreviews`.
- New `lib/ui/mock/mock_link_previews.dart`; `lib/ui/mock/mock_rooms.dart` hands it out, and the mock messages with links carry `previewLink`.
- New `lib/matrix/matrix_link_previews.dart`: `MatrixLinkPreviews`.
- `lib/matrix/matrix_rooms.dart`: owns the `MatrixLinkPreviews` and disposes of it.
- `lib/matrix/matrix_timeline.dart`: sets `previewLink` in `_message`.
- `lib/ui/shell/app_shell.dart`: `LinkPreviewsScope` beside `MediaSourceScope`.
- `lib/ui/settings/appearance_section.dart`: the "external content" line.

**Tests that change on purpose**

- `test/app_shell_rooms_test.dart`, `test/space_actions_test.dart`: `_FakeRooms` gains `linkPreviews`.

**New tests** (the spec's Testing section lists the cases)

- `test/message_markup_test.dart`: `firstWebLink`.
- `test/timeline_controller_test.dart`: the mock's `previewLink` on send and on edit.
- `test/matrix/matrix_timeline_test.dart`: which messages offer a link.
- `test/matrix/matrix_link_previews_test.dart`.
- `test/link_preview_card_test.dart`.
- `test/message_group_tile_test.dart`: where the card sits.

**Verification**

- `mise exec -- dart format --set-exit-if-changed .`
- `mise exec -- flutter analyze`
- `mise exec -- flutter test`
- `mise exec -- flutter build linux`, then by hand on loaf.moe:
  - a link the server's allowlist covers shows a card, and a tap opens it;
  - a link it does not cover shows none;
  - a link in an encrypted room shows none, and no request is made;
  - "external content" switched off removes the cards on screen;
  - with every allowlist emptied on the server, a relaunch asks for no preview.

## Deferred

Previews in encrypted rooms, more than one card per message, fetching from the device, previews while composing, keeping previews across launches, a per-room switch, video in the card.
