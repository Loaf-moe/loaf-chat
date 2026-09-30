# Loaf Chat — desktop updates

Computers update themselves; phones never do (TestFlight and the stores own
that). This spec makes the rail's update notice real: a tag on `main` builds,
signs and publishes every desktop artifact, and each installed copy fetches
the new build quietly, then offers a restart. It amends, and never
contradicts, `2026-09-20-loaf-native-design.md` ("Distribution", "Platforms")
and replaces the mock-only notice noted as deferred in
`2026-09-26-rooms-from-sync-design.md`.

It exists because the app is ready for test subjects, and nobody gets a
build until that build can replace itself.

## Scope

This is the first of three pieces. Testers get nothing until all three land.

1. **Desktop updates (this spec):** the seam, the macOS and Linux backends,
   the release pipeline, the feeds.
2. **Windows bring-up (own spec):** a Windows runner that builds, signs and
   runs.
3. **Windows updater (own spec):** one more backend behind this spec's seam.

**In:**

- An `Updater` seam the shell reads, and the notice driven by it.
- macOS: Sparkle 2, sandbox kept.
- Linux: a Flatpak from our own remote, and a self-updating AppImage.
- A tag-driven GitHub Actions release that signs and publishes everything.
- Feeds and the Flatpak remote on GitHub Pages at `get.loaf.moe`.
- The name **Loaf Chat** wherever the OS or the update system shows one.
- A `LICENSE` (AGPL-3.0-only, which the `matrix` SDK's AGPL requires).
- An install section in the README.

**Out:**

| Deferred | Why |
|---|---|
| Windows, both halves | No runner exists; pieces 2 and 3 |
| A web build | Considered and left out for now |
| Beta and stable channels | Nobody to split between yet |
| A minimum-version floor that forces an update | Declined; the feed can grow it |
| Delta updates | Full downloads are small enough for a test round |
| Linux arm64 | x86_64 first; a matrix entry later |
| Flathub | Review would delay the handout; own remote first |
| A test workflow for pull requests | No CI today; its own change |
| A download web page | The README's three links do |
| Renaming "loaf" in device names and other in-app copy | Not update work; its own pass |
| Rollback | Sparkle and Flatpak only move forward; a bad build is fixed by a higher one |

## Findings (checked 2026-09-29)

**Verified against the project or upstream documentation:**

- **The repo** is `Loaf-moe/loaf-chat`, public, default branch `main`. The
  local clone is 40 commits ahead of it and still names the old remote URL.
- **A Developer ID Application identity** (team `6W2A5N37N3`) is in the
  login keychain. macOS Release is sandboxed and signed ad hoc today.
- **Sparkle in a sandbox** needs `SUEnableInstallerLauncherService = YES`
  and the entitlement
  `com.apple.security.temporary-exception.mach-lookup.global-name` holding
  `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `-spki`. The downloader service is
  not needed: Release already has `com.apple.security.network.client`.
- **Sparkle's quiet path:**
  `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` fires
  once an automatic download is staged. Returning true hands over the
  timing; calling the block installs and relaunches with no UI. Failed
  downloads arrive at `updater(_:failedToDownloadUpdate:error:)`.
- **The Flatpak portal** (`org.freedesktop.portal.Flatpak`, version 2,
  flatpak 1.5.0): `CreateUpdateMonitor` returns a monitor whose
  `UpdateAvailable` carries `running-commit`, `local-commit` and
  `remote-commit`; `Update()` installs, reporting through `Progress`
  (`status` 0 running, 1 empty, 2 done, 3 failed); `Spawn` with flag 2
  starts the latest version. **`Update()` refuses a build that asks for a
  new permission**, with `org.freedesktop.DBus.Error.NotSupported`.
- **vodozemac** (already resolved, 0.8.0) exposes
  `Ed25519PublicKey.verify(message: String, signature:)`. The message is a
  string, so the AppImage signature covers a line of text that names the
  hash, not the file's bytes.
- **The SSO callback scheme is the macOS bundle id** (`moe.loaf.native`,
  `lib/matrix/sso_browser.dart`), so that id stays.
- **Names today disagree:** `loaf_native` (macOS product, Android label),
  "Loaf Native" (iOS), "Loaf" (Linux title, `MaterialApp`).

**Not verified; each gets a throwaway probe as the plan's first tasks:**

- Whether the portal shows a permission dialog the first time an app calls
  `Update()`. If it does, quiet on Flatpak means one system prompt, once.
- That Sparkle, with a user driver that shows nothing, reaches the staged
  state without a reply this design does not give.
- That `flutter build macos --release` yields a universal vodozemac library.
- That SSO's loopback listener and browser hand-off work inside the Flatpak
  sandbox.

## Naming

The app is **Loaf Chat**.

| Where | Becomes |
|---|---|
| macOS `PRODUCT_NAME` (bundle, menu bar, window title) | `Loaf Chat` |
| Linux window and header bar title | `Loaf Chat` |
| Linux `BINARY_NAME` | `loaf-chat` |
| Linux `APPLICATION_ID`, and the Flatpak id | `moe.loaf.chat` |
| iOS `CFBundleDisplayName`, Android `android:label` | `Loaf Chat` |
| `MaterialApp.title` | `Loaf Chat` |
| The notice | `loaf chat 0.3.0 is ready` (the app's copy stays lowercase) |
| Artifacts | `Loaf-Chat-<version>.dmg`, `Loaf-Chat-<version>-x86_64.AppImage` |

The macOS and iOS bundle id stays `moe.loaf.native`: nobody sees it, and
SSO's callback scheme is built on it. The Dart package stays `loaf_native`.

## The seam

The shell knows one thing, an `Updater`, and never what stands behind it.
This follows the `Rooms` precedent: a plain interface under `lib/ui/model/`,
real backends elsewhere, and `lib/main.dart` choosing between them.

`lib/ui/model/updater.dart`:

- `abstract class Updater implements Listenable` with `UpdateState get state`,
  `Future<void> restart()` and `void dispose()`.
- `UpdateState` is one of:

| State | Meaning | The shell shows |
|---|---|---|
| `idle` | Nothing newer is known | Nothing |
| `preparing` | A newer build is being checked, fetched or verified | Nothing |
| `ready(version)` | Staged and verified on disk | The notice |
| `applying` | The restart was asked for and cannot be stopped | The notice, action busy, no dismiss |

- `version` is nullable. Without one the notice reads "a new loaf chat is
  ready".
- `restart()` is valid only in `ready`.
- `NoUpdater`: always `idle`. `FakeUpdater`: settable, for tests and the mock.

`lib/update/` holds the backends and `Updater pickUpdater()`. Only
`lib/main.dart` imports it.

| Environment | Backend |
|---|---|
| Debug or profile build, any platform | `NoUpdater` |
| macOS release | `SparkleUpdater` |
| Linux with `FLATPAK_ID` set | `FlatpakUpdater` |
| Linux with `APPIMAGE` set | `AppImageUpdater` |
| Windows | `NoUpdater`, until piece 3 |
| Anything else, phones included | `NoUpdater` |

**Rules every backend keeps:**

- The notice appears only for an update already verified on disk.
- A failure is never a notice. It is logged, the state returns to `idle`,
  and the next check tries again. A tester cannot act on "update failed".
- The first check runs shortly after launch, then every six hours.
- An update nobody restarts into applies when the app next quits.

**The shell:** `_showUpdate` and the `MockSession` test go. The notice shows
when `isDesktop`, the state is `ready` or `applying`, and that version was
not dismissed this launch. Dismissing is the shell's memory, not the
updater's, and lasts until the next launch. `MockSession` runs with a
`FakeUpdater` already `ready('0.3.0')`, so the mock-up keeps its tile
through the real path.

## Backends

### macOS: Sparkle 2

- Sparkle joins the Runner as a Swift package. One Swift class owns an
  `SPUUpdater` and speaks to Dart over the method channel
  `moe.loaf.chat/updater`: state events up, `restart` down.
- **No Sparkle windows.** A user driver answers every prompt itself:
  permission to check, yes; update found, fetch it; ready to install, hold
  the reply; error, acknowledge. Loaf Chat's notice is the only UI.
- `Info.plist`: `SUFeedURL` (`https://get.loaf.moe/appcast.xml`),
  `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`,
  `SUScheduledCheckInterval` of 21600, `SUEnableInstallerLauncherService`.
- `ready(version)` is the delegate's install-on-quit call, answered true
  with the block kept. `restart()` calls the block.
- The sandbox stays on, with the two mach-lookup entitlements added to
  `Release.entitlements`.
- Sparkle verifies the download against the EdDSA key; Gatekeeper verifies
  the notarization.

### Linux, Flatpak: the portal

- A Dart D-Bus client (the `dbus` package, a new dependency) creates an
  update monitor.
- `UpdateAvailable` with `local-commit` differing from `running-commit`:
  the system already installed it. `ready` at once.
- `UpdateAvailable` with `remote-commit` differing from `local-commit`:
  `preparing`, call `Update()`, follow `Progress`; status 2 is `ready`,
  status 3 is `idle`.
- `restart()`: `Spawn` with flag 2, then exit.
- The portal speaks in commits, so the version comes from `latest.json`.
  If that fetch fails, `ready(null)`.
- A portal that is missing or older than version 2 means `NoUpdater`. The
  system's software centre still updates the app.
- **Permissions are declared once, up front,** calls included, because a
  release that adds one cannot be installed from inside the app.

### Linux, AppImage: our own

- Fetch `latest.json`. Act only when its `build` is higher than ours.
- Download to a temporary file beside `$APPIMAGE`.
- Check the file's SHA-256 against the manifest, and the manifest's
  signature against the Ed25519 public key compiled into the app. The
  signed text is `loaf-chat-appimage\n<version>\n<build>\n<sha256>`.
- Mark it executable and rename it over `$APPIMAGE`. The rename is atomic:
  a crash leaves the old file or the new one, never half of each. That is
  `ready(version)`.
- `restart()`: start `$APPIMAGE` detached, then exit.
- A folder that cannot be written means `idle` and a log line.
- New direct dependencies: `crypto` (already resolved), and vodozemac's
  verify reached through `lib/update/` only.

### Windows

`NoUpdater`. Piece 3 chooses between WinSparkle, Velopack and MSIX. Its one
constraint from here is the four states above.

## The release pipeline

**Cutting a release is pushing a tag** like `v0.1.0` that sits on `main`.

- The tag is the version name. `pubspec.yaml` stops deciding it.
- The build number is the commit count on `main`. Every updater compares
  build numbers, so they only go up. A tag not on `main` fails the run.

`.github/workflows/release.yml` runs on `v*` tags only, never on pull
requests, in a `release` environment that only those tags may use.

| Job | Runner | Does |
|---|---|---|
| `macos` | `macos-latest` | Universal release build signed with Developer ID and the hardened runtime; DMG; notarize and staple; Sparkle signature |
| `linux` | `ubuntu-latest` | One `flutter build linux --release`, packaged as a Flatpak commit and as a signed AppImage |
| `publish` | `ubuntu-latest` | Only if both passed |

**Publish order:** assets go to a draft GitHub Release; then the feeds and
the OSTree repo go to Pages; then the Release leaves draft. A feed never
names a file that is not there, and a half-failed release is invisible.

**GitHub Release assets:** the DMG, the AppImage.

**GitHub Pages** (`gh-pages` branch, served as `get.loaf.moe`):

| Path | What |
|---|---|
| `appcast.xml` | Sparkle's feed; the latest build only |
| `latest.json` | `version`, `build`, and the AppImage's `url`, `sha256`, `size`, `signature` |
| `repo/` | The Flatpak OSTree repo, GPG-signed, branch `stable` |
| `loaf-chat.flatpakref` | What a Linux tester opens to install; carries the remote and its key |
| `CNAME` | `get.loaf.moe` |

The OSTree repo is pruned to the last three builds, and each release
rewrites `gh-pages` as a single commit so its history does not grow. Pages
allows 1 GB a site and 100 MB a file.

**Secrets**, in the `release` environment:

- Developer ID certificate and its password
- App Store Connect API key, for notarization
- Sparkle EdDSA private key
- Flatpak GPG private key
- AppImage Ed25519 private key

**Done once, by hand, by Chris** (the plan writes out each step):

- Enable Pages on `gh-pages`; point `get.loaf.moe` at it with a DNS record.
- Create the `release` environment, limited to `v*` tags.
- Generate the three signing keys, enter them and the Apple credentials as
  secrets, and keep an offline copy. A lost key strands every install that
  trusts it.
- Commit the three public keys where the builds read them.

## Failure handling

| Situation | What happens |
|---|---|
| No network, or the feed is unreachable | `idle`, logged, retried in six hours |
| A download cut off part-way | The partial file is discarded; retried |
| A signature or hash that does not match | The file is deleted, an error is logged, no notice |
| The feed offers the same build or an older one | Ignored |
| Restart asked for, and the install fails | The old build keeps running; the notice returns next launch |
| AppImage folder not writable | `idle`, logged |
| Flatpak release adds a permission | `Update()` refuses; `idle`. The software centre installs it |
| Flatpak portal missing or too old | `NoUpdater` |
| A bad release | Publish a higher version |

## Testing

- **Seam and shell** (widget tests, `FakeUpdater`): the notice only in
  `ready` and `applying`; dismiss hides that version until a new shell;
  no dismiss while `applying`; a phone never shows it; the mock still
  shows `0.3.0`. The existing update-notice tests move onto the seam.
- **AppImage updater** (`test()`, a local HTTP server, a temporary folder):
  a good update swaps the file; a bad signature, a bad hash, a cut-off
  download, a read-only folder and an older build each leave the file
  untouched and the state `idle`.
- **Flatpak updater** (`test()`, a fake portal object on a private bus):
  both `UpdateAvailable` cases, a failed `Update()`, a refused one, a
  missing `latest.json`, a portal below version 2.
- **Sparkle updater:** Dart tests fake the method channel. The Swift bridge
  is thin and checked by hand.
- **`pickUpdater`:** one test per row of its table.
- **The pipeline** has no unit tests. It is proved by a rehearsal, which is
  this spec's acceptance test: release `v0.1.0`; install it fresh on macOS,
  from the Flatpak ref, and as an AppImage; sign in on each; release
  `v0.1.1`; watch each copy show the notice and restart into `0.1.1`.
