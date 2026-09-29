# SDK Wiring Roadmap

> **Status:** phases 1–5 have landed, each from its own rehearsed plan (`2026-09-26-real-sign-in.md`, `2026-09-26-rooms-from-sync.md`, `2026-09-27-timeline.md`, `2026-09-27-e2ee.md`, `2026-09-27-channel-space-actions.md`). The app now talks to a real homeserver by default. Every later phase gets its own plan when it comes up.

**Goal:** Replace the mock source behind the finished UI with matrix-dart-sdk. Phases are ordered by what gets the app to "daily-drivable on loaf.moe" soonest for the least work.

**Spec:** `docs/superpowers/specs/2026-09-20-loaf-native-design.md` (Stack, Layering, Process) and `2026-09-24-calls-design.md`.

## Findings that shape every phase (verified 2026-09-26)

- **The SDK is now `matrix` 13.0.0, not the spec's ^12.0.1.** 13.0.0 (2026-09-22) has a breaking change to `prev_content` handling. It resolves cleanly with `flutter_vodozemac` 0.8.1, `sqflite_common_ffi` 2.4.3, `flutter_web_auth_2` 5.1.0 and `url_launcher` 6.3.2 on Flutter 3.47.5, and it builds for macOS and the iOS simulator through Swift Package Manager. Phase 1 corrects the spec.
- **The offline test harness works.** A real `Client` over `FakeMatrixApi` with an in-memory `sqflite_common_ffi` database discovers, signs in and runs a first sync of fake rooms under `flutter test`. Phase 2's room mapping can be tested against that sync.
- **`FakeMatrixApi` accepts any password.** Error paths need `package:http/testing.dart`'s `MockClient`.
- **Don't discover through the SDK.** `Client.getVersions` caches under one key for every server, so it answers for the wrong server. `checkHomeserver` swallows well-known failures and `assert(false)`s on version mismatches. Phase 1 discovers over plain HTTP.
- **Device keys load after a sync is announced.** Straight after sign-in, "no master key" means "not loaded yet", not "no identity". Listen for `SyncStatus.finished`, which fires after keys update; `onSync` fires before.
- **Soft logout in the SDK is a token refresh.** It announces `softLoggedOut`, refreshes, and either goes back to `loggedIn` or clears the session. The spec's locked "welcome back" screen needs its own design.
- **An offline launch restores fine.** `client.init()` with a stored session returns signed in within about 10 ms with no network; sync reports an error and retries.
- **loaf.moe (tuwunel, spec v1.19)** offers password, token and SSO with one provider `{id: tuwunel, name: loaf.moe, brand: kanidm}`. It accepts both a loopback redirect (`http://127.0.0.1:<port>/sso`) and a custom-scheme redirect (`moe.loaf.native://sso`). It also advertises MSC3861 `/auth_metadata`. Chris's account is SSO-only.
- **The seams:** everything outside `lib/ui/mock/` reaches the mock through `MockSession`, `SignInController`'s answers, `VerificationController`, `TimelineController`, `CallController`, and the fixtures that `app_shell.dart` (986 lines) layers its session changes over.

## Phases, by bang for buck

| # | Phase | Why here | Size |
|---|---|---|---|
| 1 | **Real sign-in:** Kanidm SSO (sheet on phones, browser on computers), password, a session that survives relaunch, sign out, trust from the SDK | Unblocks everything, and an SSO-only account can't get in without SSO. **Plan: `2026-09-26-real-sign-in.md`** | M |
| 2 | **Rooms from sync:** rail, channel lists, Home sections, unreads, members | The first moment the app shows *your* loaf.moe. Read-only, so low risk **Plan: `2026-09-26-rooms-from-sync.md`** | M |
| 3 | **Timeline:** read, send text, reply, react, edit, delete, read markers, pagination | Makes it usable for unencrypted rooms. `TimelineController`'s API already matches (`send`, `toggleReaction`, `saveEdit`, `delete`) **Plan: `2026-09-27-timeline.md`** | M |
| 4 | **E2EE:** verify by emoji, recovery key, set up recovery, key backup restore, the incoming "is this you?" | Without it encrypted DMs are unreadable. vodozemac is already initialised by phase 1; the UI and `VerificationController` exist, so swap timers for `KeyVerification` and `Bootstrap` **Plan: `2026-09-27-e2ee.md`** | M–L |
| 5 | **Channel and space actions:** join, leave, mute (push rule), DMs without duplicates, invites, `/hierarchy` browse, create space, tags and favourites | Every flow is already designed, and each is a thin call **Plan: `2026-09-27-channel-space-actions.md`** | M |
| 6 | **Presence and status, profile, settings** | Cheap polish | S |
| 7 | **Voice channels** (MatrixRTC + `livekit_client`), connected-call bar, occupancy avatars | High delight, but heavy and needs a device | L |
| 8 | **APNs push via Sygnal, DM ringing** (CallKit/PushKit, MSC4075) | Mac-only work, scheduled around Mac access | L |
| 9 | Images and files, media viewer | Part of the v1 messaging scope, and independent of the phases above | M |

Phases 5, 6 and 9 are independent once phase 3 lands and can go to parallel subagents. Phases 7 and 8 depend on 4 for call media keys. The default backend flipped from `mock` to `matrix` when phase 3 landed; `--dart-define=LOAF_BACKEND=mock` plays the mock.

## Deferred from phase 1, to place later

- **The soft-logout "welcome back" screen** (see the findings above). Until then an expired, unrefreshable token signs out.
- **MSC3861 OIDC sign-in.** loaf.moe advertises it, but `m.login.sso` works today.
- **Encrypting the sqlite database at rest** (sqlcipher, with a key in the Keychain) before anyone but Chris uses the app.
- **Android's SSO callback activity** (best-effort platform).
- **A widget-level test of `SessionRoot` over `MatrixSession`** (sign-in flips to the shell, and the post-frame dispose closes the homeserver). It needs a fake-backed session inside the widget tester's fake clock.
- **Pressing Enter in the password field during the point of no return** reaches the submit handler, which is a no-op there. The fields could be read-only while signing in, to be fully honest.
- ~~**Reset identity's re-sign-in** must use `ssoInBrowser`.~~ Superseded by phase 4: re-authentication's SSO is the server's fallback page, which hands nothing back, so it opens in the real browser on every platform with an "i've finished" step.
- **Small tidy-ups:** `sso()` and `_signIn()` both look up `_bases`; `openClient` calls `sqfliteFfiInit()` on every call; the failure note and the server-check note on the sign-in screen are two identical blocks; `MatrixSession.open()` itself has no test.

## Deferred from phase 2, to place later

- ~~**Unjoined channels from `/hierarchy`**, and joining a space's category subspaces and suggested channels (phase 5, with joining).~~ Done in phase 5.
- **Voice occupancy avatars** need a `VoIP` instance to read MatrixRTC memberships (phase 7).
- **Avatar images** (`mxc` thumbnails) for spaces, rooms and people (phase 6 or 9). Initials on a colour until then.
- **Presence of others** is `Presence.unknown` until phase 6.
- **Marking read on opening** waits for read markers (phase 3); until then a real room's unread count stays after reading it elsewhere only until the next sync.
- **Rail order** is alphabetical. Element orders spaces by the `org.matrix.msc3230.space_order` account data; adopt it if it matters.
- **Member lists of very large rooms** load whole into memory when shown (`requestParticipants` with `cache: true`). Fine for loaf.moe; page them if a 10k-member room appears.
- **The debug menu's call levers** still ring mock DMs on the real backend (debug builds only).

## Deferred from phase 3, to place later

- **Typing indicators, read receipts under messages, the unread divider and a jump-to-newest pill.** Each is new UI the spec does not draw yet.
- **State events as timeline lines** (joins, leaves, renames, topics). They are skipped until then.
- **Rich formatting, both ways.** Messages display as plain text, and send as plain text with no markdown, so what you see is what went out.
- **Fetching a reply's target that is not loaded.** The quote is a stub ("a message further up") until then.
- **Evicting cached timelines.** Every room opened stays open until sign-out; fine at loaf.moe's size, like large member lists.
- **The composer's + and paperclip buttons** do nothing on either backend. They belong to media (phase 9); until then they are controls with nothing behind them.
- **A toast for a refused reaction, edit or delete only shows while its room is on screen.** The screen still snaps back to what the server has.
- **Voice channels read "messages aren't wired up yet"**, which an existing test pins, until calls land in phase 7.
- **"didn't send" takes minutes to appear offline** (found by hand, 2026-09-27). Two SDK defaults stack: `Client.sendTimelineEventTimeout` is 1 minute of retrying once a second, and the plain `http.Client` from `openClient` has no per-request timeout, so one attempt on a dead network hangs until the OS drops the TCP connection; the SDK checks its deadline only after an attempt fails. Candidate fix: a shorter window and a timeout on send requests only (sync long-polls for 30s by design). Chris's call: leave it until phase 9, since a send timeout would also bound image uploads.
- **Edit is offered on file and emote rows**; saving turns a file into a text message. It should be text and notice rows only.
- **`MatrixRooms.markRead` can target the SDK's `refreshingLastEvent` placeholder or a discarded echo.** It fails silently and heals itself.
- **A room that fails to open reads "couldn't load older messages · try again" over an empty room.** It works, but the copy misleads.
- **The failed line's retry and discard, and the older row's "try again", are small tap targets on a phone.**
- **Two app instances on one store fight over its lock** (`database is locked` from `BEGIN IMMEDIATE`, seen when a stale `flutter run` was still up). A second launch could detect a store in use and say so.
- **`test/matrix/` tests flake under load**: `matrix_session_test` and several `matrix_timeline_test` cases fail intermittently, on `main` too, with `database_closed` and timing asserts. A separate session is on it.

## Deferred from phase 4, to place later

- **QR verification,** and **verifying other people.** Another person's request is left to time out: there is no panel for it.
- **An account whose secret storage holds no cross-signing keys** hears that its key "unlocks nothing", which is true but not the whole story. It needs another device, or a reset.
- **Reset's SSO re-authentication is tested offline only.** The live run used a password account.
- **Encryption tests need the macOS build first** (`flutter build macos --debug`); a fresh clone fails them with that instruction. A test-only build of vodozemac would lift it.
- **A restore does not resume after a quit.** Rooms fetch missing keys from backup as they open, so nothing is lost, only the count.
- **Key backup without cross-signing is not healed by the key.** Such an account is offered setting up, which refuses and offers reset, since healing needs a re-auth inside unlocking.
- **Minor leftovers from the task reviews:** the restore count counts keys attempted, not stored; making an identity takes every re-auth request on the client, not only its own; a re-auth "retry" also shows after a passed stage of a multi-stage flow; the panel's composer choice listens to the timeline, but a trust flip really arrives through the shell's rebuild on the session changing.
- **A server that refuses a re-auth stage reads "couldn't reach".** A set-up or reset the server turned down (not a wrong password) says it couldn't reach the server, which is not the whole story.
- **No test signs out during a restore, and `Verifier` has no `dispose`.** A restore running unseen when the session ends is left to the SDK's own teardown.
- **A device list in settings, where a sign-in can be signed out.** "that's not me" says to sign the device out from another app, since settings can't yet; point it there once it can.
- **A backup-only account hears "that didn't unlock anything".** Key backup without cross-signing isn't healed by the key (above), and the key panel's answer doesn't say why.

## Deferred from phase 5, to place later

- **Space settings, roles and power levels.** This is new UI the spec does not draw.
- **Knocking.** Knock-only rooms and spaces are hidden rather than offered.
- **Inviting by email (3PID).** loaf.moe has no identity server.
- **Removing a room from a space, or adding an existing one.** This is space administration, and comes with settings.
- **A panel dismissed mid-create.** It is blocked instead. On phones, a panel that can create or start a DM loses swipe-down-to-close even when idle, because Flutter's sheet drag pops past `PopScope`.
- **Group DM reuse matches on the room summary's heroes,** which are capped at 5, so a group of more than 5 people always gets a new DM.
- **Joining a space can cost two `/hierarchy` requests,** and leaving one walks every other joined space's tree. Both are fine at loaf.moe's size.
- **Favourite or low priority can roll back the display when their second call fails** though the first landed; the next sync heals it.
- **`createDirect` can throw a bare StateError** if a reused DM is not yet in Home after sync; it should say so plainly.
- **The explore panel's server list** is a fixed `loaf.moe` and `matrix.org`, plus whatever you type.
- **`test/matrix/matrix_timeline_test.dart` flakes on most full-suite runs on `main` too** (checked 2026-09-28: 3 of 4 runs had one or two failures, a different test each time). It passes alone. This joins the phase 3 note about it.

## Global constraints (all phases)

- Only `lib/matrix/` (and `lib/main.dart`, which picks the backend) imports `package:matrix` and the native plugins. `lib/ui/` keeps rendering plain models. Mapping happens on read. There is no second stored model: the SDK is the store.
- The mock backend stays forever, for tests, previews and the debug levers.
- Existing tests must pass **unchanged** through each refactor. They are the safety net that proves the seam kept behaviour.
- Split by `isDesktop`, lowercase warm copy, no hardcoded text metrics, Nushell-compatible commands, and `mise exec -- flutter analyze` / `test`.
- Commits happen only when Chris asks. Each task ends with a checkpoint and a conventional commit message that ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
