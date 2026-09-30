# Desktop Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A tag on `main` builds, signs and publishes Loaf Chat for macOS and Linux, and every installed copy fetches the new build quietly and then offers a restart from the rail.

**Architecture:**
- **One seam, `Updater`,** in `lib/ui/model/`. The shell reads its state and calls `restart()`. It never learns the platform.
- **Three backends in a new `lib/update/`:** Sparkle 2 on macOS (a Swift bridge over a method channel), the Flatpak portal over D-Bus, and our own updater for an AppImage. `lib/main.dart` picks one at launch.
- **One workflow, `release.yml`,** runs on `v*` tags. Release assets go to GitHub Releases; the feeds and the Flatpak repo go to GitHub Pages at `get.loaf.moe`.

**Tech Stack:** Flutter 3.47.5 via `mise exec -- flutter`; Sparkle 2 (Swift package); new Dart dependencies `dbus`, and `crypto` and `vodozemac` promoted from transitive to direct; GitHub Actions; `flatpak-builder`; `appimagetool`. Release scripts are bash because they run on CI runners.

**Spec:** `docs/superpowers/specs/2026-09-29-desktop-updates-design.md`. Read it first, including its **Findings**.

**Not rehearsed.** Like the phase 5 and 6 plans, this gives interfaces, tests and the key code. Implementers read the files named in each task before editing. If the code disagrees with this plan, stop and say so.

**Two tasks need Chris, not an agent:** Task 7 (signing keys) and Task 11 (GitHub, DNS and Apple setup). They handle private keys. Stop at each and hand over.

## Global Constraints

- **The app is Loaf Chat.** In-app copy stays lowercase: `loaf chat 0.3.0 is ready`.
- **The import rule:**
  - `lib/ui/` never imports `lib/update/` or `lib/matrix/`.
  - Only `lib/main.dart` imports `lib/update/`.
  - `lib/update/` never imports `package:matrix`. It logs through `updateLog`.
- **The notice appears only for an update already verified on disk.**
- **A failure is never a notice.** Log it, return to `UpdateIdle`, and let the next check try again.
- **Honest controls:** no dismiss and no live action while `UpdateApplying`.
- **Identifiers, exactly:**
  - Linux application id and Flatpak id: `moe.loaf.chat`
  - Linux binary: `loaf-chat`
  - macOS and iOS bundle id: `moe.loaf.native` (unchanged)
  - Method channel: `moe.loaf.chat/updater`
  - Feed base: `https://get.loaf.moe`
  - Repo: `Loaf-moe/loaf-chat`
  - Signed text for the AppImage: `loaf-chat-appimage\n<version>\n<build>\n<sha256>`
- **Build numbers decide what is newer,** never version names. A build number of 0 means the build did not come from the pipeline, and gets no updater.
- **Existing tests pass unchanged,** except these mechanical edits, each named in its task:
  - Task 3: `test/app_shell_test.dart` swaps the tooltip `loaf 0.3.0 is ready` for `loaf chat 0.3.0 is ready`, twice.
- **Commands:** `mise exec -- flutter test` needs the macOS debug build once (`mise exec -- flutter build macos --debug`), as the README says.

## Review Focus

Each line has its test in the task that owns the code.

1. **`$APPIMAGE` is a symlink** (a link in `~/bin` to the real file). The swap replaces the real file and leaves the link. Task 5.
2. **The feed is not a feed** (a captive portal's HTML, a missing field, `build` as a string). The updater stays idle and nothing throws. Tasks 4 and 5.
3. **A version was dismissed, then a newer one becomes ready in the same run.** The notice comes back. Task 3.
4. **The portal reports the same update twice, or again mid-install.** `Update()` is called once. Task 6.
5. **A release build made by hand, run as an AppImage or Flatpak.** It has build number 0, so it gets no updater and never "updates" itself to the published build. Task 9.

---

### Task 1: Loaf Chat, by name, and a licence

**Files:**
- Modify: `macos/Runner/Configs/AppInfo.xcconfig`
- Modify: `macos/Runner.xcodeproj/project.pbxproj` (lines 68, 137, 227, 401, 415, 429)
- Modify: `macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme` (five `BuildableName`s)
- Modify: `linux/CMakeLists.txt:7,10`
- Modify: `linux/runner/my_application.cc:48,52`
- Modify: `ios/Runner/Info.plist` (`CFBundleDisplayName`)
- Modify: `android/app/src/main/AndroidManifest.xml:3`
- Modify: `lib/main.dart:50`
- Create: `LICENSE`
- Modify: `README.md`

**Interfaces:**
- Produces: the macOS app at `build/macos/Build/Products/<Config>/Loaf Chat.app`; the Linux binary `loaf-chat`; the Linux application id `moe.loaf.chat`.

- [ ] **Step 1: Rename on macOS**

In `AppInfo.xcconfig`:

```
PRODUCT_NAME = Loaf Chat
```

In `project.pbxproj` replace `loaf_native.app` with `Loaf Chat.app` on lines 68, 137 and 227 (quote it: `"Loaf Chat.app"`), and set all three `TEST_HOST` lines to:

```
TEST_HOST = "$(BUILT_PRODUCTS_DIR)/Loaf Chat.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Loaf Chat";
```

In `Runner.xcscheme` set every `BuildableName = "loaf_native.app"` to `BuildableName = "Loaf Chat.app"`.

Leave `PRODUCT_BUNDLE_IDENTIFIER` alone: SSO's callback scheme is built on it.

- [ ] **Step 2: Rename on Linux**

`linux/CMakeLists.txt`:

```cmake
set(BINARY_NAME "loaf-chat")
set(APPLICATION_ID "moe.loaf.chat")
```

`linux/runner/my_application.cc`: both `"Loaf"` titles become `"Loaf Chat"`.

- [ ] **Step 3: Rename on phones and in Dart**

- `ios/Runner/Info.plist`: `CFBundleDisplayName` becomes `Loaf Chat`.
- `AndroidManifest.xml`: `android:label="Loaf Chat"`.
- `lib/main.dart`: `title: 'Loaf Chat'`.

- [ ] **Step 4: Add the licence**

```bash
curl -fsSL https://www.gnu.org/licenses/agpl-3.0.txt -o LICENSE
```

In `README.md`, change the heading to `# Loaf Chat` and add at the end:

```markdown
## Licence

AGPL-3.0-only. See `LICENSE`.
```

- [ ] **Step 5: Verify**

Run: `mise exec -- flutter build macos --debug`
Expected: succeeds, and `build/macos/Build/Products/Debug/Loaf Chat.app` exists.

Run: `mise exec -- flutter test`
Expected: all pass. The vodozemac library path in `test/matrix/crypto_harness.dart` does not include the app's name.

- [ ] **Step 6: Commit**

```bash
git add -A macos linux ios android lib/main.dart LICENSE README.md
git commit -m "chore: the app is Loaf Chat, under the AGPL"
```

---

### Task 2: The `Updater` seam

**Files:**
- Create: `lib/ui/model/updater.dart`
- Test: `test/updater_test.dart`

**Interfaces:**
- Produces:
  - `sealed class UpdateState` with `UpdateIdle()`, `UpdatePreparing()`, `UpdateReady(String? version)`, `UpdateApplying(String? version)`, all `const`.
  - `abstract class Updater implements Listenable { UpdateState get state; Future<void> restart(); void dispose(); }`
  - `class NoUpdater implements Updater` with a `const` constructor.
  - `class FakeUpdater extends ChangeNotifier implements Updater` with `FakeUpdater([UpdateState])`, a `state` setter that notifies, and `int restarts`.

- [ ] **Step 1: Write the failing tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/updater.dart';

void main() {
  test('no updater is idle, and restarting it does nothing', () async {
    const updater = NoUpdater();
    updater.addListener(() => fail('it never changes'));
    await updater.restart();
    expect(updater.state, isA<UpdateIdle>());
  });

  test('a fake tells its listeners when its state is set', () {
    final updater = FakeUpdater();
    addTearDown(updater.dispose);
    var told = 0;
    updater.addListener(() => told++);
    updater.state = const UpdateReady('0.4.0');
    expect(told, 1);
    expect((updater.state as UpdateReady).version, '0.4.0');
  });

  test('restarting a fake is counted, and leaves it idle', () async {
    final updater = FakeUpdater(const UpdateReady('0.4.0'));
    addTearDown(updater.dispose);
    await updater.restart();
    expect(updater.restarts, 1);
    expect(updater.state, isA<UpdateIdle>());
  });
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `mise exec -- flutter test test/updater_test.dart`
Expected: a compile failure, `updater.dart` does not exist.

- [ ] **Step 3: Write the seam**

```dart
/// How this copy of the app replaces itself with a newer one. The shell
/// reads this and nothing else: which platform mechanism stands behind it
/// (Sparkle, the Flatpak portal, our own for an AppImage) is `lib/update/`'s
/// business. Phones have none; the stores own their updates.
library;

import 'package:flutter/foundation.dart';

sealed class UpdateState {
  const UpdateState();
}

/// Nothing newer is known.
final class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

/// A newer build is being checked, fetched or verified. Not shown: there is
/// nothing to do about it yet.
final class UpdatePreparing extends UpdateState {
  const UpdatePreparing();
}

/// Staged and verified on disk. [version] is null when the platform only
/// knows that something newer is there.
final class UpdateReady extends UpdateState {
  const UpdateReady(this.version);
  final String? version;
}

/// The restart was asked for and cannot be stopped.
final class UpdateApplying extends UpdateState {
  const UpdateApplying(this.version);
  final String? version;
}

abstract class Updater implements Listenable {
  UpdateState get state;

  /// Restarts into the staged build. Only means anything in [UpdateReady].
  Future<void> restart();

  void dispose();
}

/// A copy of the app that nothing updates: a debug build, a phone, a
/// platform with no backend yet.
class NoUpdater implements Updater {
  const NoUpdater();

  @override
  UpdateState get state => const UpdateIdle();

  @override
  Future<void> restart() async {}

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  void dispose() {}
}

/// Says whatever it is told to, for tests and the mock.
class FakeUpdater extends ChangeNotifier implements Updater {
  FakeUpdater([this._state = const UpdateIdle()]);

  UpdateState _state;
  int restarts = 0;

  @override
  UpdateState get state => _state;

  set state(UpdateState value) {
    _state = value;
    notifyListeners();
  }

  /// As if the app had restarted: the notice has nothing left to say.
  @override
  Future<void> restart() async {
    restarts++;
    state = const UpdateIdle();
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `mise exec -- flutter test test/updater_test.dart`
Expected: 3 pass.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/model/updater.dart test/updater_test.dart
git commit -m "feat(update): an Updater seam the shell can read"
```

---

### Task 3: The shell reads the seam

**Files:**
- Modify: `lib/ui/shell/app_notice.dart:33-44` (`AppNotice.update`) and `_NoticeDetails`
- Modify: `lib/ui/shell/app_shell.dart` (constructor, `initState`, `dispose`, line 149, lines 826-834)
- Modify: `lib/ui/auth/session_root.dart` (pass the updater through)
- Modify: `test/app_shell_test.dart:167,176` (the tooltip text)
- Test: `test/update_notice_test.dart`

**Interfaces:**
- Consumes: `Updater`, `UpdateState` and its subclasses, `NoUpdater`, `FakeUpdater` from Task 2.
- Produces:
  - `AppShell({super.key, this.session, this.rooms, this.updater})` with `final Updater? updater`.
  - `SessionRoot({super.key, required this.session, this.rooms, this.updater})` with `final Updater? updater`.
  - `AppNotice.update({String? version, bool applying = false, VoidCallback? onAction, VoidCallback? onDismiss})`.

- [ ] **Step 1: Write the failing tests**

`test/update_notice_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/model/updater.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);
final _phone = TargetPlatformVariant.only(TargetPlatform.iOS);

Future<FakeUpdater> _pump(
  WidgetTester tester,
  UpdateState state, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final updater = FakeUpdater(state);
  addTearDown(updater.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      home: AppShell(updater: updater),
    ),
  );
  await tester.pumpAndSettle();
  return updater;
}

Finder _tile(String title) => find.byTooltip(title);

void main() {
  testWidgets('nothing shows while idle or preparing', variant: _mac, (
    tester,
  ) async {
    final updater = await _pump(tester, const UpdateIdle());
    expect(find.byIcon(LucideIcons.arrowDownToLine), findsNothing);
    updater.state = const UpdatePreparing();
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.arrowDownToLine), findsNothing);
  });

  testWidgets('a ready update is a tile that names its version', variant: _mac, (
    tester,
  ) async {
    final updater = await _pump(tester, const UpdateIdle());
    updater.state = const UpdateReady('0.4.0');
    await tester.pumpAndSettle();
    expect(_tile('loaf chat 0.4.0 is ready'), findsOneWidget);
  });

  testWidgets('without a version it still says something is ready', variant: _mac, (
    tester,
  ) async {
    await _pump(tester, const UpdateReady(null));
    expect(_tile('a new loaf chat is ready'), findsOneWidget);
  });

  testWidgets('restart asks the updater to restart', variant: _mac, (
    tester,
  ) async {
    final updater = await _pump(tester, const UpdateReady('0.4.0'));
    await tester.tap(_tile('loaf chat 0.4.0 is ready'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('restart'));
    await tester.pumpAndSettle();
    expect(updater.restarts, 1);
  });

  testWidgets('later hides that version, and a newer one comes back', variant: _mac, (
    tester,
  ) async {
    final updater = await _pump(tester, const UpdateReady('0.4.0'));
    await tester.tap(_tile('loaf chat 0.4.0 is ready'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('later'));
    await tester.pumpAndSettle();
    expect(_tile('loaf chat 0.4.0 is ready'), findsNothing);
    expect(updater.restarts, 0);

    // Said again, it stays put away.
    updater.state = const UpdateReady('0.4.0');
    await tester.pumpAndSettle();
    expect(_tile('loaf chat 0.4.0 is ready'), findsNothing);

    // Something newer is news.
    updater.state = const UpdateReady('0.4.1');
    await tester.pumpAndSettle();
    expect(_tile('loaf chat 0.4.1 is ready'), findsOneWidget);
  });

  testWidgets('while applying there is no later and no live action', variant: _mac, (
    tester,
  ) async {
    final updater = await _pump(tester, const UpdateApplying('0.4.0'));
    await tester.tap(_tile('loaf chat 0.4.0 is ready'));
    await tester.pumpAndSettle();
    expect(find.text('later'), findsNothing);
    await tester.tap(find.text('restarting…'));
    await tester.pumpAndSettle();
    expect(updater.restarts, 0);
  });

  testWidgets('a phone never shows it', variant: _phone, (tester) async {
    await _pump(
      tester,
      const UpdateReady('0.4.0'),
      size: const Size(390, 844),
    );
    await tester.tap(find.byIcon(LucideIcons.menu));
    await tester.pumpAndSettle();
    expect(_tile('loaf chat 0.4.0 is ready'), findsNothing);
  });
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `mise exec -- flutter test test/update_notice_test.dart`
Expected: a compile failure, `AppShell` has no `updater` parameter.

- [ ] **Step 3: The notice**

Replace `AppNotice.update` in `app_notice.dart`:

```dart
  /// An update is ready to install. Desktop only — on a phone the App Store
  /// or TestFlight owns updates, so the shell never creates this there.
  /// [applying] is the restart under way: it cannot be stopped, so it
  /// offers no dismiss and its action is dead.
  factory AppNotice.update({
    String? version,
    bool applying = false,
    VoidCallback? onAction,
    VoidCallback? onDismiss,
  }) => AppNotice(
    icon: LucideIcons.arrowDownToLine,
    title: version == null
        ? 'a new loaf chat is ready'
        : 'loaf chat $version is ready',
    body: applying
        ? 'restarting into the new version'
        : 'restart to pick up the new version',
    actionLabel: applying ? 'restarting…' : 'restart',
    onAction: applying ? null : onAction,
    onDismiss: applying ? null : onDismiss,
  );
```

In `_NoticeDetails`, the action button goes dead when the notice has no action:

```dart
            LoafButton(
              label: notice.actionLabel,
              onTap: notice.onAction == null
                  ? null
                  : () => Navigator.pop(context, _Choice.act),
```

- [ ] **Step 4: The shell**

In `app_shell.dart`, import `dart:async` if it is not already, and `../model/updater.dart`.

Constructor and field:

```dart
  const AppShell({super.key, this.session, this.rooms, this.updater});

  /// What replaces this copy of the app with a newer one. The app passes
  /// its one updater, which outlives the shell. Left out, the mock plays an
  /// update that is ready and a real session has none.
  final Updater? updater;
```

State, beside `_rooms`:

```dart
  late final Updater _updater =
      widget.updater ??
      (_session is MockSession
          ? FakeUpdater(const UpdateReady('0.3.0'))
          : const NoUpdater());
```

In `initState` add `_updater.addListener(_onChange);`. In `dispose` add:

```dart
    _updater.removeListener(_onChange);
    if (widget.updater == null) _updater.dispose();
```

Replace the `_showUpdate` field (line 149) with:

```dart
  /// The update put off with "later", until the next launch. The empty
  /// string stands for one that came without a version.
  String? _laterUpdate;

  AppNotice? get _updateNotice => switch (_updater.state) {
    UpdateReady(:final version) when _laterUpdate != (version ?? '') =>
      AppNotice.update(
        version: version,
        onAction: () => unawaited(_updater.restart()),
        onDismiss: () => setState(() => _laterUpdate = version ?? ''),
      ),
    UpdateApplying(:final version) => AppNotice.update(
      version: version,
      applying: true,
    ),
    _ => null,
  };
```

Replace the last entry of `_notices` (lines 826-834) with:

```dart
    // Phones update through the App Store or TestFlight, never in-app.
    if (isDesktop) ?_updateNotice,
```

In `session_root.dart` add `this.updater` to the constructor, the field `final Updater? updater;` with the comment `/// The app's one updater. Left out, the shell decides.`, and pass `updater: widget.updater` to `AppShell`.

- [ ] **Step 5: The mechanical edit to existing tests**

In `test/app_shell_test.dart` change `'loaf 0.3.0 is ready'` to `'loaf chat 0.3.0 is ready'` on lines 167 and 176.

- [ ] **Step 6: Run the tests**

Run: `mise exec -- flutter test test/update_notice_test.dart test/app_shell_test.dart test/app_shell_rooms_test.dart`
Expected: all pass, including the untouched `no update notice: nothing stands behind it yet`.

- [ ] **Step 7: Commit**

```bash
git add lib/ui test/update_notice_test.dart test/app_shell_test.dart
git commit -m "feat(update): the rail's update notice follows the updater"
```

---

### Task 4: The release feed and its signature

**Files:**
- Modify: `pubspec.yaml` (add `crypto` and `vodozemac` as direct dependencies, at the versions in `pubspec.lock`)
- Create: `lib/update/update_log.dart`
- Create: `lib/update/release_feed.dart`
- Create: `lib/update/ed25519.dart`
- Test: `test/update/release_feed_test.dart`
- Test: `test/update/ed25519_test.dart`

**Interfaces:**
- Produces:
  - `void updateLog(String message, [Object? error, StackTrace? stack])`
  - `class Release { String version; int build; AppImageAsset? appImage; static Release parse(String body); String get signedText; }` — `parse` throws `FormatException` on anything that is not a feed.
  - `class AppImageAsset { Uri url; String sha256; int size; String signature; }`
  - `Future<Release> fetchRelease(http.Client client, Uri feed)`
  - `typedef SignatureCheck = bool Function(String message, String signature);`
  - `SignatureCheck ed25519Check(String publicKey)` — base64 in, never throws.

- [ ] **Step 1: Write the failing feed tests**

`test/update/release_feed_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loaf_native/update/release_feed.dart';

const _feed = '''
{"version":"0.1.1","build":412,"appimage":{
  "url":"https://github.com/Loaf-moe/loaf-chat/releases/download/v0.1.1/Loaf-Chat-0.1.1-x86_64.AppImage",
  "sha256":"abc123","size":1024,"signature":"c2ln"}}
''';

void main() {
  test('a feed parses', () {
    final release = Release.parse(_feed);
    expect(release.version, '0.1.1');
    expect(release.build, 412);
    expect(release.appImage!.size, 1024);
    expect(release.appImage!.url.host, 'github.com');
  });

  test('the signed text names the version, the build and the hash', () {
    expect(
      Release.parse(_feed).signedText,
      'loaf-chat-appimage\n0.1.1\n412\nabc123',
    );
  });

  test('a feed with no AppImage still says its version', () {
    final release = Release.parse('{"version":"0.1.1","build":412}');
    expect(release.appImage, isNull);
  });

  for (final (name, body) in [
    ('a web page', '<html><body>sign in to the wifi</body></html>'),
    ('a list', '[1, 2, 3]'),
    ('no build', '{"version":"0.1.1"}'),
    ('a build that is a string', '{"version":"0.1.1","build":"412"}'),
    ('nothing', ''),
  ]) {
    test('$name is not a feed', () {
      expect(() => Release.parse(body), throwsFormatException);
    });
  }

  test('fetching refuses anything but a 200', () async {
    final client = MockClient((_) async => http.Response('gone', 404));
    await expectLater(
      fetchRelease(client, Uri.parse('https://get.loaf.moe/latest.json')),
      throwsA(isA<Exception>()),
    );
  });

  test('fetching returns the release', () async {
    final client = MockClient((_) async => http.Response(_feed, 200));
    final release = await fetchRelease(
      client,
      Uri.parse('https://get.loaf.moe/latest.json'),
    );
    expect(release.build, 412);
  });
}
```

- [ ] **Step 2: Run to see them fail**

Run: `mise exec -- flutter test test/update/release_feed_test.dart`
Expected: a compile failure.

- [ ] **Step 3: Write the log and the feed**

`lib/update/update_log.dart`:

```dart
/// Where the updaters say what went wrong. A failed update is never shown
/// to anyone, so this line is the only trace of it.
library;

import 'package:flutter/foundation.dart';

void updateLog(String message, [Object? error, StackTrace? stack]) {
  debugPrint('[loaf update] $message${error == null ? '' : ': $error'}');
  if (stack != null) debugPrintStack(stackTrace: stack, maxFrames: 8);
}
```

`lib/update/release_feed.dart`:

```dart
/// `latest.json`: what the newest release is, and where its AppImage lives.
/// The AppImage updater acts on it; the Flatpak updater only reads the
/// version out of it, because the portal speaks in commits.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class AppImageAsset {
  const AppImageAsset({
    required this.url,
    required this.sha256,
    required this.size,
    required this.signature,
  });

  final Uri url;
  final String sha256;
  final int size;

  /// Ed25519 over [Release.signedText], base64.
  final String signature;
}

class Release {
  const Release({required this.version, required this.build, this.appImage});

  final String version;

  /// What decides newer from older. Version names are for people.
  final int build;
  final AppImageAsset? appImage;

  /// Throws a [FormatException] for anything that is not a feed: a captive
  /// portal's page, a truncated body, a field of the wrong type.
  static Release parse(String body) {
    final json = jsonDecode(body);
    if (json case {'version': final String version, 'build': final int build}) {
      return Release(
        version: version,
        build: build,
        appImage: switch (json['appimage']) {
          {
            'url': final String url,
            'sha256': final String sha256,
            'size': final int size,
            'signature': final String signature,
          } =>
            AppImageAsset(
              url: Uri.parse(url),
              sha256: sha256,
              size: size,
              signature: signature,
            ),
          _ => null,
        },
      );
    }
    throw const FormatException('not a release feed');
  }

  /// What the release key signs. It names the hash rather than being the
  /// file: the verifier takes text, and the hash then vouches for the file.
  String get signedText =>
      'loaf-chat-appimage\n$version\n$build\n${appImage!.sha256}';
}

Future<Release> fetchRelease(http.Client client, Uri feed) async {
  final response = await client.get(feed).timeout(const Duration(seconds: 30));
  if (response.statusCode != 200) {
    throw HttpException('the feed answered ${response.statusCode}', uri: feed);
  }
  return Release.parse(response.body);
}
```

- [ ] **Step 4: Run the feed tests**

Run: `mise exec -- flutter test test/update/release_feed_test.dart`
Expected: all pass.

- [ ] **Step 5: Write the failing signature tests**

Read `~/.pub-cache/hosted/pub.dev/vodozemac-0.8.0/lib/src/api.dart:54-102` first, for `Ed25519PublicKey` and `Ed25519Signature`. The vector is RFC 8032 §7.1 test 1, whose message is empty, so it is a string the API can take. It pins the format that `openssl` signs in.

`test/update/ed25519_test.dart`:

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/update/ed25519.dart';

import '../matrix/crypto_harness.dart';

String _b64(String hex) => base64.encode([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

// RFC 8032, 7.1, test 1: the empty message.
final _key = _b64(
  'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
);
final _signature = _b64(
  'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb882159'
  '0a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
);

void main() {
  setUpAll(loadVodozemac);

  test('a true signature checks out, padded base64 or not', () {
    expect(ed25519Check(_key)('', _signature), isTrue);
    expect(
      ed25519Check(_key.replaceAll('=', ''))('', _signature.replaceAll('=', '')),
      isTrue,
    );
  });

  test('the same signature over other text does not', () {
    expect(ed25519Check(_key)('loaf', _signature), isFalse);
  });

  test('rubbish is a no, not a crash', () {
    expect(ed25519Check(_key)('', 'not base64 at all!'), isFalse);
    expect(ed25519Check('')('', _signature), isFalse);
  });
}
```

- [ ] **Step 6: Run to see them fail, then write the check**

Run: `mise exec -- flutter test test/update/ed25519_test.dart`
Expected: a compile failure.

`lib/update/ed25519.dart`:

```dart
/// Ed25519 by way of vodozemac, which the app already carries for Matrix.
/// vodozemac must be initialised first; `MatrixSession.open` does that.
library;

import 'package:vodozemac/vodozemac.dart' as vod;

typedef SignatureCheck = bool Function(String message, String signature);

/// A check against one base64 public key. Never throws: a key or signature
/// that cannot even be read is simply not a match.
SignatureCheck ed25519Check(String publicKey) => (message, signature) {
  try {
    // vodozemac reads unpadded base64; openssl and `base64` write padding.
    vod.Ed25519PublicKey.fromBase64(publicKey.replaceAll('=', '')).verify(
      message: message,
      signature: vod.Ed25519Signature.fromBase64(signature.replaceAll('=', '')),
    );
    return true;
  } catch (_) {
    return false;
  }
};
```

If the constructor names in `api.dart` differ from `fromBase64`, use the ones that are there.

- [ ] **Step 7: Run all of this task's tests**

Run: `mise exec -- flutter test test/update/`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/update test/update
git commit -m "feat(update): the release feed, and a signature check for it"
```

---

### Task 5: The AppImage updater

**Files:**
- Create: `lib/update/state_updater.dart`
- Create: `lib/update/appimage_updater.dart`
- Test: `test/update/appimage_updater_test.dart`

**Interfaces:**
- Consumes: `Updater`, `UpdateState` (Task 2); `fetchRelease`, `Release`, `SignatureCheck`, `updateLog` (Task 4).
- Produces:
  - `abstract class StateUpdater extends ChangeNotifier implements Updater` with `@protected void move(UpdateState next)`, which does nothing once disposed.
  - `class AppImageUpdater extends StateUpdater` with
    `AppImageUpdater({required File appImage, required int build, required Uri feed, required SignatureCheck verify, http.Client? httpClient, Future<void> Function(String path)? launch, void Function()? quit})`,
    `void start()`, and `Future<void> check()`.

- [ ] **Step 1: Write the failing tests**

These are `test()`, not `testWidgets()`: they do real I/O, which the widget tester's fake clock stalls.

`test/update/appimage_updater_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/updater.dart';
import 'package:loaf_native/update/appimage_updater.dart';

const _old = 'the old build';
const _new = 'the new build, which is longer';

class _Server {
  _Server(this._http);
  final HttpServer _http;

  /// What `latest.json` and the download answer with. Tests change these.
  String feed = '';
  List<int> download = utf8.encode(_new);
  bool cutDownloadShort = false;

  Uri get feedUri => Uri.parse('http://localhost:${_http.port}/latest.json');
  Uri get downloadUri => Uri.parse('http://localhost:${_http.port}/app');

  static Future<_Server> start() async {
    final server = _Server(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    server._http.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/latest.json') {
        response.write(server.feed);
      } else if (server.cutDownloadShort) {
        // Promises more than it sends, so the connection drops part-way.
        response.contentLength = server.download.length;
        response.add(server.download.sublist(0, 4));
        try {
          await response.close();
        } catch (_) {}
        return;
      } else {
        response.add(server.download);
      }
      await response.close();
    });
    return server;
  }

  /// A feed for [body] at [build], signed `good` unless told otherwise.
  void offer({int build = 2, String? sha, String signature = 'good'}) {
    feed = jsonEncode({
      'version': '0.1.$build',
      'build': build,
      'appimage': {
        'url': '$downloadUri',
        'sha256': sha ?? sha256.convert(download).toString(),
        'size': download.length,
        'signature': signature,
      },
    });
  }

  Future<void> close() => _http.close(force: true);
}

void main() {
  late _Server server;
  late Directory dir;
  late File appImage;
  final launched = <String>[];
  var quits = 0;

  AppImageUpdater updater({File? at}) {
    final u = AppImageUpdater(
      appImage: at ?? appImage,
      build: 1,
      feed: server.feedUri,
      verify: (message, signature) => signature == 'good',
      launch: (path) async => launched.add(path),
      quit: () => quits++,
    );
    addTearDown(u.dispose);
    return u;
  }

  setUp(() async {
    server = await _Server.start();
    dir = await Directory.systemTemp.createTemp('loaf-appimage');
    appImage = File('${dir.path}/Loaf-Chat.AppImage')..writeAsStringSync(_old);
    launched.clear();
    quits = 0;
  });

  tearDown(() async {
    await server.close();
    // A test may have made the folder read-only.
    Process.runSync('chmod', ['-R', 'u+w', dir.path]);
    dir.deleteSync(recursive: true);
  });

  bool leftovers() =>
      dir.listSync().any((entry) => entry.path.endsWith('.part'));

  test('a newer, signed build replaces the file and is ready', () async {
    server.offer();
    final u = updater();
    await u.check();
    expect(u.state, isA<UpdateReady>());
    expect((u.state as UpdateReady).version, '0.1.2');
    expect(appImage.readAsStringSync(), _new);
    expect(appImage.statSync().modeString(), contains('x'));
    expect(leftovers(), isFalse);
  });

  test('restarting launches the file and quits', () async {
    server.offer();
    final u = updater();
    await u.check();
    await u.restart();
    expect(launched, [appImage.path]);
    expect(quits, 1);
    expect(u.state, isA<UpdateApplying>());
  });

  test('restarting before anything is ready does nothing', () async {
    final u = updater();
    await u.restart();
    expect(launched, isEmpty);
    expect(quits, 0);
  });

  test('a launch that fails leaves the update ready', () async {
    server.offer();
    final u = AppImageUpdater(
      appImage: appImage,
      build: 1,
      feed: server.feedUri,
      verify: (_, signature) => signature == 'good',
      launch: (_) async => throw const FileSystemException('no'),
      quit: () => quits++,
    );
    addTearDown(u.dispose);
    await u.check();
    await u.restart();
    expect(quits, 0);
    expect(u.state, isA<UpdateReady>());
  });

  for (final (name, arrange) in <(String, void Function())>[
    ('the same build', () => server.offer(build: 1)),
    ('an older build', () => server.offer(build: 0)),
    ('a bad signature', () => server.offer(signature: 'forged')),
    ('a hash that does not match', () => server.offer(sha: 'ab' * 32)),
    ('a web page where the feed should be', () => server.feed = '<html>'),
    ('a feed with no AppImage', () {
      server.feed = '{"version":"0.1.2","build":2}';
    }),
    ('a download cut short', () {
      server
        ..offer()
        ..cutDownloadShort = true;
    }),
  ]) {
    test('$name leaves the file alone', () async {
      arrange();
      final u = updater();
      await u.check();
      expect(u.state, isA<UpdateIdle>());
      expect(appImage.readAsStringSync(), _old);
      expect(leftovers(), isFalse);
    });
  }

  test('a feed nobody answers leaves the file alone', () async {
    await server.close();
    final u = updater();
    await u.check();
    expect(u.state, isA<UpdateIdle>());
    expect(appImage.readAsStringSync(), _old);
  });

  test('a folder that cannot be written leaves the file alone', () async {
    server.offer();
    Process.runSync('chmod', ['u-w', dir.path]);
    final u = updater();
    await u.check();
    expect(u.state, isA<UpdateIdle>());
    expect(appImage.readAsStringSync(), _old);
  });

  test('a symlink is followed: the real file is replaced', () async {
    server.offer();
    final bin = await Directory('${dir.path}/bin').create();
    final link = Link('${bin.path}/loaf')..createSync(appImage.path);
    final u = updater(at: File(link.path));
    await u.check();
    expect(u.state, isA<UpdateReady>());
    expect(FileSystemEntity.isLinkSync(link.path), isTrue);
    expect(appImage.readAsStringSync(), _new);
  });

  test('a check while one is running is not a second download', () async {
    server.offer();
    final u = updater();
    await Future.wait([u.check(), u.check()]);
    expect(u.state, isA<UpdateReady>());
    expect(leftovers(), isFalse);
  });

  test('once ready, later checks leave it be', () async {
    server.offer();
    final u = updater();
    await u.check();
    server.feed = '<html>';
    await u.check();
    expect(u.state, isA<UpdateReady>());
  });
}
```

- [ ] **Step 2: Run to see them fail**

Run: `mise exec -- flutter test test/update/appimage_updater_test.dart`
Expected: a compile failure.

- [ ] **Step 3: Write the base and the updater**

`lib/update/state_updater.dart`:

```dart
/// What the real updaters share: a state, and listeners told when it moves.
library;

import 'package:flutter/foundation.dart';

import '../ui/model/updater.dart';

abstract class StateUpdater extends ChangeNotifier implements Updater {
  UpdateState _state = const UpdateIdle();
  bool _disposed = false;

  @override
  UpdateState get state => _state;

  /// Does nothing after [dispose]: downloads and platform calls finish
  /// whenever they finish, and may find the updater gone.
  @protected
  void move(UpdateState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
```

`lib/update/appimage_updater.dart`:

```dart
/// Updates an AppImage, which nothing else will: no system mechanism knows
/// the file exists. Fetches the feed, downloads beside the running file,
/// checks the signature and the hash, and renames over it. The rename is
/// atomic, so a crash leaves the old file or the new one, never a mix.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../ui/model/updater.dart';
import 'ed25519.dart';
import 'release_feed.dart';
import 'state_updater.dart';
import 'update_log.dart';

class AppImageUpdater extends StateUpdater {
  AppImageUpdater({
    required File appImage,
    required this.build,
    required this.feed,
    required this.verify,
    http.Client? httpClient,
    Future<void> Function(String path)? launch,
    void Function()? quit,
  }) : _appImage = appImage,
       _http = httpClient ?? http.Client(),
       _launch = launch ?? _launchDetached,
       _quit = quit ?? _exit;

  final File _appImage;

  /// This copy's build number.
  final int build;
  final Uri feed;
  final SignatureCheck verify;
  final http.Client _http;
  final Future<void> Function(String path) _launch;
  final void Function() _quit;

  final _timers = <Timer>[];
  bool _checking = false;

  /// Nothing sane is this big; refuse before filling the disk.
  static const _largest = 500 * 1024 * 1024;

  /// Checks shortly after launch, then every six hours.
  void start() {
    _timers
      ..add(Timer(const Duration(seconds: 30), check))
      ..add(Timer.periodic(const Duration(hours: 6), (_) => check()));
  }

  Future<void> check() async {
    if (_checking || state is! UpdateIdle) return;
    _checking = true;
    File? part;
    try {
      final release = await fetchRelease(_http, feed);
      final asset = release.appImage;
      if (asset == null || release.build <= build) return;
      if (!verify(release.signedText, asset.signature)) {
        throw StateError('the feed is not signed by the release key');
      }
      if (asset.size > _largest) throw StateError('${asset.size} bytes');
      move(const UpdatePreparing());

      // $APPIMAGE may be a link into ~/bin: replace what it points at.
      final target = File(await _appImage.resolveSymbolicLinks());
      part = File('${target.path}.part');
      final response = await _http.send(http.Request('GET', asset.url));
      if (response.statusCode != 200) {
        throw HttpException('${response.statusCode}', uri: asset.url);
      }
      await response.stream.pipe(part.openWrite());
      final length = await part.length();
      final digest = await sha256.bind(part.openRead()).first;
      if (length != asset.size || '$digest' != asset.sha256) {
        throw StateError('the download does not match the feed');
      }
      final chmod = await Process.run('chmod', ['+x', part.path]);
      if (chmod.exitCode != 0) throw StateError('chmod: ${chmod.stderr}');
      await part.rename(target.path);
      part = null;
      move(UpdateReady(release.version));
    } catch (e, s) {
      updateLog('the AppImage was not updated', e, s);
      move(const UpdateIdle());
    } finally {
      try {
        if (part != null && part.existsSync()) part.deleteSync();
      } catch (_) {}
      _checking = false;
    }
  }

  @override
  Future<void> restart() async {
    final ready = state;
    if (ready is! UpdateReady) return;
    move(UpdateApplying(ready.version));
    try {
      await _launch(_appImage.path);
    } catch (e, s) {
      updateLog('the new AppImage did not start', e, s);
      move(ready);
      return;
    }
    _quit();
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _http.close();
    super.dispose();
  }
}

Future<void> _launchDetached(String path) =>
    Process.start(path, const [], mode: ProcessStartMode.detached);

void _exit() => exit(0);
```

Note the state only becomes `UpdatePreparing` once a newer, signed build is known, so a routine check that finds nothing never leaves idle.

- [ ] **Step 4: Run the tests**

Run: `mise exec -- flutter test test/update/appimage_updater_test.dart`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/update test/update/appimage_updater_test.dart
git commit -m "feat(update): an AppImage replaces itself, atomically"
```

---

### Task 6: The Flatpak updater

**Files:**
- Modify: `pubspec.yaml` (add `dbus`, the current release; check its API docs before writing the client)
- Create: `lib/update/flatpak_portal.dart`
- Create: `lib/update/dbus_flatpak_portal.dart`
- Create: `lib/update/flatpak_updater.dart`
- Test: `test/update/flatpak_updater_test.dart`

**Interfaces:**
- Consumes: `StateUpdater` (Task 5), `updateLog` (Task 4).
- Produces:
  - `class UpdateCommits { String running; String local; String remote; }`
  - `abstract class FlatpakPortal { Future<int> version(); Stream<UpdateCommits> watch(); Future<void> update(); Future<void> spawnLatest(); Future<void> close(); }`
  - `class DbusFlatpakPortal implements FlatpakPortal`
  - `class FlatpakUpdater extends StateUpdater` with
    `FlatpakUpdater({required FlatpakPortal portal, required Future<String?> Function() version, void Function()? quit})` and `Future<void> start()`.

The spec's tests spoke of a fake portal on a private bus. The tests run on macOS, which has no session bus, so the fake sits one level up, behind `FlatpakPortal`. `DbusFlatpakPortal` is thin and is proved in the rehearsal (Task 12).

- [ ] **Step 1: Write the failing tests**

`test/update/flatpak_updater_test.dart`:

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/updater.dart';
import 'package:loaf_native/update/flatpak_portal.dart';
import 'package:loaf_native/update/flatpak_updater.dart';

class _Portal implements FlatpakPortal {
  int portalVersion = 2;
  bool missing = false;
  final commits = StreamController<UpdateCommits>();
  int updates = 0;
  int spawns = 0;
  Completer<void> installing = Completer();
  Object? spawnFails;

  @override
  Future<int> version() async =>
      missing ? throw StateError('no portal') : portalVersion;

  @override
  Stream<UpdateCommits> watch() => commits.stream;

  @override
  Future<void> update() {
    updates++;
    return installing.future;
  }

  @override
  Future<void> spawnLatest() async {
    if (spawnFails != null) throw spawnFails!;
    spawns++;
  }

  @override
  Future<void> close() async {}
}

const _installedAlready = UpdateCommits(running: 'a', local: 'b', remote: 'b');
const _onTheRemote = UpdateCommits(running: 'a', local: 'a', remote: 'b');
const _nothing = UpdateCommits(running: 'a', local: 'a', remote: 'a');

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  late _Portal portal;
  var quits = 0;
  String? feedVersion;

  Future<FlatpakUpdater> started() async {
    final u = FlatpakUpdater(
      portal: portal,
      version: () async => feedVersion,
      quit: () => quits++,
    );
    addTearDown(u.dispose);
    await u.start();
    return u;
  }

  setUp(() {
    portal = _Portal();
    quits = 0;
    feedVersion = '0.1.2';
  });

  test('a build the system already installed is ready at once', () async {
    final u = await started();
    portal.commits.add(_installedAlready);
    await _turn();
    expect((u.state as UpdateReady).version, '0.1.2');
    expect(portal.updates, 0);
  });

  test('a build on the remote is installed, then ready', () async {
    final u = await started();
    portal.commits.add(_onTheRemote);
    await _turn();
    expect(u.state, isA<UpdatePreparing>());
    expect(portal.updates, 1);
    portal.installing.complete();
    await _turn();
    expect((u.state as UpdateReady).version, '0.1.2');
  });

  test('the same update said twice is installed once', () async {
    final u = await started();
    portal.commits
      ..add(_onTheRemote)
      ..add(_onTheRemote);
    await _turn();
    portal.commits.add(_onTheRemote);
    await _turn();
    expect(portal.updates, 1);
    portal.installing.complete();
    await _turn();
    portal.commits.add(_installedAlready);
    await _turn();
    expect(portal.updates, 1);
    expect(u.state, isA<UpdateReady>());
  });

  test('an install the portal fails or refuses goes back to idle', () async {
    final u = await started();
    portal.commits.add(_onTheRemote);
    await _turn();
    portal.installing.completeError(StateError('NotSupported'));
    await _turn();
    expect(u.state, isA<UpdateIdle>());
  });

  test('matching commits are not an update', () async {
    final u = await started();
    portal.commits.add(_nothing);
    await _turn();
    expect(u.state, isA<UpdateIdle>());
  });

  test('without the feed it is ready with no version', () async {
    feedVersion = null;
    final u = await started();
    portal.commits.add(_installedAlready);
    await _turn();
    expect((u.state as UpdateReady).version, isNull);
  });

  test('a version lookup that throws is ready with no version', () async {
    final u = FlatpakUpdater(
      portal: portal,
      version: () async => throw StateError('offline'),
      quit: () => quits++,
    );
    addTearDown(u.dispose);
    await u.start();
    portal.commits.add(_installedAlready);
    await _turn();
    expect((u.state as UpdateReady).version, isNull);
  });

  test('a portal older than version 2 is never watched', () async {
    portal.portalVersion = 1;
    final u = await started();
    expect(portal.commits.hasListener, isFalse);
    expect(u.state, isA<UpdateIdle>());
  });

  test('no portal at all is just idle', () async {
    portal.missing = true;
    final u = await started();
    expect(portal.commits.hasListener, isFalse);
    expect(u.state, isA<UpdateIdle>());
  });

  test('restarting spawns the latest build and quits', () async {
    final u = await started();
    portal.commits.add(_installedAlready);
    await _turn();
    await u.restart();
    expect(portal.spawns, 1);
    expect(quits, 1);
    expect(u.state, isA<UpdateApplying>());
  });

  test('a spawn that fails leaves the update ready', () async {
    final u = await started();
    portal.commits.add(_installedAlready);
    await _turn();
    portal.spawnFails = StateError('no');
    await u.restart();
    expect(quits, 0);
    expect(u.state, isA<UpdateReady>());
  });
}
```

- [ ] **Step 2: Run to see them fail**

Run: `mise exec -- flutter test test/update/flatpak_updater_test.dart`
Expected: a compile failure.

- [ ] **Step 3: Write the portal interface and the updater**

`lib/update/flatpak_portal.dart`:

```dart
/// The part of `org.freedesktop.portal.Flatpak` the updater needs, as an
/// interface, so the updater is tested without a session bus.
library;

class UpdateCommits {
  const UpdateCommits({
    required this.running,
    required this.local,
    required this.remote,
  });

  /// The build this process is.
  final String running;

  /// The build a restart would start.
  final String local;

  /// The build the remote offers.
  final String remote;
}

abstract class FlatpakPortal {
  /// The portal's interface version. Throws when there is no portal.
  Future<int> version();

  /// Each update the portal notices. Listening starts its monitor.
  Stream<UpdateCommits> watch();

  /// Installs the remote build. Completes when it is installed; throws when
  /// the portal fails, or refuses because the build wants a new permission.
  Future<void> update();

  /// Starts the newest installed build.
  Future<void> spawnLatest();

  Future<void> close();
}
```

`lib/update/flatpak_updater.dart`:

```dart
/// Updates a Flatpak through the portal: the system does the fetching,
/// verifying and installing, and this only follows along.
library;

import 'dart:async';
import 'dart:io';

import '../ui/model/updater.dart';
import 'flatpak_portal.dart';
import 'state_updater.dart';
import 'update_log.dart';

class FlatpakUpdater extends StateUpdater {
  FlatpakUpdater({
    required this.portal,
    required this.version,
    void Function()? quit,
  }) : _quit = quit ?? (() => exit(0));

  final FlatpakPortal portal;

  /// The newest release's version name, from the feed: the portal speaks in
  /// commits. Null, or a throw, means the notice goes without one.
  final Future<String?> Function() version;
  final void Function() _quit;

  StreamSubscription<UpdateCommits>? _watching;

  /// Update monitors arrived in version 2 of the portal (flatpak 1.5).
  static const _monitors = 2;

  Future<void> start() async {
    try {
      if (await portal.version() < _monitors) return;
    } catch (e) {
      updateLog('no Flatpak portal; the software centre updates this', e);
      return;
    }
    _watching = portal.watch().listen(
      _onCommits,
      onError: (Object e, StackTrace s) => updateLog('the portal', e, s),
    );
  }

  Future<void> _onCommits(UpdateCommits commits) async {
    // Said again mid-install, or once it is ready: already in hand.
    if (state is! UpdateIdle) return;
    if (commits.local != commits.running) {
      // The system got there first.
      move(const UpdatePreparing());
      move(UpdateReady(await _version()));
    } else if (commits.remote != commits.local) {
      move(const UpdatePreparing());
      try {
        await portal.update();
        move(UpdateReady(await _version()));
      } catch (e, s) {
        updateLog('the Flatpak was not updated', e, s);
        move(const UpdateIdle());
      }
    }
  }

  Future<String?> _version() async {
    try {
      return await version();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> restart() async {
    final ready = state;
    if (ready is! UpdateReady) return;
    move(UpdateApplying(ready.version));
    try {
      await portal.spawnLatest();
    } catch (e, s) {
      updateLog('the new Flatpak did not start', e, s);
      move(ready);
      return;
    }
    _quit();
  }

  @override
  void dispose() {
    unawaited(_watching?.cancel());
    unawaited(portal.close());
    super.dispose();
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `mise exec -- flutter test test/update/flatpak_updater_test.dart`
Expected: all pass.

- [ ] **Step 5: Write the D-Bus portal**

Check each call against the `dbus` package's API docs as you write it. The portal's own definition is `data/org.freedesktop.portal.Flatpak.xml` in `github.com/flatpak/flatpak`.

`lib/update/dbus_flatpak_portal.dart`:

```dart
/// [FlatpakPortal] over the session bus. Kept thin: everything that decides
/// anything is in `flatpak_updater.dart`, where it can be tested.
library;

import 'dart:convert';

import 'package:dbus/dbus.dart';

import 'flatpak_portal.dart';

class DbusFlatpakPortal implements FlatpakPortal {
  static const _name = 'org.freedesktop.portal.Flatpak';
  static const _monitorInterface = 'org.freedesktop.portal.Flatpak.UpdateMonitor';

  /// FLATPAK_SPAWN_FLAGS_LATEST_VERSION.
  static const _latestVersion = 2;

  final _bus = DBusClient.session();
  late final _portal = DBusRemoteObject(
    _bus,
    name: _name,
    path: DBusObjectPath('/org/freedesktop/portal/Flatpak'),
  );
  DBusRemoteObject? _monitor;

  @override
  Future<int> version() async => (await _portal.getProperty(
    _name,
    'version',
    signature: DBusSignature('u'),
  )).asUint32();

  Future<DBusRemoteObject> _open() async {
    final reply = await _portal.callMethod(
      _name,
      'CreateUpdateMonitor',
      [DBusDict.stringVariant(const {})],
      replySignature: DBusSignature('o'),
    );
    return _monitor = DBusRemoteObject(
      _bus,
      name: _name,
      path: reply.returnValues.single.asObjectPath(),
    );
  }

  Stream<Map<String, DBusValue>> _signals(DBusRemoteObject monitor, String name) =>
      DBusRemoteObjectSignalStream(
        object: monitor,
        interface: _monitorInterface,
        name: name,
        signature: DBusSignature('a{sv}'),
      ).map((signal) => signal.values.single.asStringVariantDict());

  @override
  Stream<UpdateCommits> watch() async* {
    final monitor = _monitor ?? await _open();
    await for (final info in _signals(monitor, 'UpdateAvailable')) {
      yield UpdateCommits(
        running: info['running-commit']?.asString() ?? '',
        local: info['local-commit']?.asString() ?? '',
        remote: info['remote-commit']?.asString() ?? '',
      );
    }
  }

  @override
  Future<void> update() async {
    final monitor = _monitor ?? await _open();
    // Status: 0 running, 1 nothing to do, 2 done, 3 failed.
    final finished = _signals(monitor, 'Progress')
        .firstWhere((progress) => (progress['status']?.asUint32() ?? 0) != 0);
    await monitor.callMethod(
      _monitorInterface,
      'Update',
      [const DBusString(''), DBusDict.stringVariant(const {})],
      replySignature: DBusSignature(''),
    );
    final last = await finished;
    if (last['status']?.asUint32() != 2) {
      throw StateError(
        last['error_message']?.asString() ?? 'the portal did not update',
      );
    }
  }

  @override
  Future<void> spawnLatest() => _portal.callMethod(
    _name,
    'Spawn',
    [
      _bytes('/'),
      DBusArray(DBusSignature('ay'), [_bytes('loaf-chat')]),
      DBusDict(DBusSignature('u'), DBusSignature('h'), const {}),
      DBusDict(DBusSignature('s'), DBusSignature('s'), const {}),
      const DBusUint32(_latestVersion),
      DBusDict.stringVariant(const {}),
    ],
    replySignature: DBusSignature('u'),
  );

  /// The portal takes paths and arguments as NUL-terminated bytes.
  static DBusArray _bytes(String text) =>
      DBusArray.byte([...utf8.encode(text), 0]);

  @override
  Future<void> close() async {
    final monitor = _monitor;
    _monitor = null;
    try {
      await monitor?.callMethod(
        _monitorInterface,
        'Close',
        const [],
        replySignature: DBusSignature(''),
      );
    } finally {
      await _bus.close();
    }
  }
}
```

- [ ] **Step 6: Verify and commit**

Run: `mise exec -- flutter analyze lib/update` — Expected: no issues.
Run: `mise exec -- flutter test test/update/` — Expected: all pass.

```bash
git add pubspec.yaml pubspec.lock lib/update test/update/flatpak_updater_test.dart
git commit -m "feat(update): a Flatpak updates through the portal"
```

---

### Task 7: Signing keys (Chris)

**This task handles private keys. An agent writes the script and stops. Chris runs it.**

**Files:**
- Create: `tool/release/keygen.sh`
- Create (by the script): `tool/release/keys/appimage.pub`, `tool/release/keys/sparkle.pub`, `tool/release/keys/flatpak.asc`

**Interfaces:**
- Produces: three public keys, committed, that Tasks 8, 9 and 10 read; three private keys in a folder outside the repo, which Task 11 enters as secrets.

- [ ] **Step 1: Write the script**

`tool/release/keygen.sh`:

```bash
#!/usr/bin/env bash
# Makes the three release signing keys. Run once, on a Mac.
# Private keys go to the folder you name, which must be outside the repo.
# Public keys go to tool/release/keys/, to be committed.
set -euo pipefail

private="${1:?usage: keygen.sh <folder outside the repo for private keys>}"
public="$(cd "$(dirname "$0")" && pwd)/keys"
sparkle_version="${SPARKLE_VERSION:-2.8.0}"

case "$(cd "$(dirname "$private")" && pwd)/" in
  "$(git rev-parse --show-toplevel)"/*) echo "that folder is inside the repo" >&2; exit 1 ;;
esac
mkdir -p "$private" "$public"
chmod 700 "$private"

# The AppImage key: Ed25519, read by lib/update/ed25519.dart.
openssl genpkey -algorithm ed25519 -out "$private/appimage-private.pem"
openssl pkey -in "$private/appimage-private.pem" -pubout -outform DER \
  | tail -c 32 | base64 > "$public/appimage.pub"

# Sparkle's key, made by Sparkle's own tool so its format is Sparkle's.
work="$(mktemp -d)"
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" \
  | tar -xJ -C "$work"
"$work/bin/generate_keys" --account moe.loaf.chat >/dev/null
"$work/bin/generate_keys" --account moe.loaf.chat -p > "$public/sparkle.pub"
"$work/bin/generate_keys" --account moe.loaf.chat -x "$private/sparkle-private.txt"

# The Flatpak repo's key: GPG, no passphrase, because CI signs unattended.
export GNUPGHOME="$private/gnupg"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key \
  'Loaf Chat releases <releases@loaf.moe>' ed25519 sign never
gpg --armor --export > "$public/flatpak.asc"
gpg --armor --export-secret-keys > "$private/flatpak-private.asc"

echo "public keys:  $public  (commit these)"
echo "private keys: $private  (copy offline; never commit)"
```

`chmod +x tool/release/keygen.sh`. If the Sparkle version 404s, set `SPARKLE_VERSION` to the newest 2.x on its releases page, and use that same version in Tasks 8 and 10.

- [ ] **Step 2: Commit the script, then stop and hand over**

```bash
git add tool/release/keygen.sh
git commit -m "chore(release): a script that makes the signing keys"
```

Tell Chris, verbatim:

> Run this once (needs OpenSSL 3 and gpg; `brew install openssl@3 gnupg` if missing):
>
> ```bash
> bash tool/release/keygen.sh ~/loaf-chat-release-keys
> ```
>
> Then copy `~/loaf-chat-release-keys` somewhere offline. Losing a key strands every install that trusts it.

- [ ] **Step 3: After Chris has run it, commit the public keys**

Check that all three files in `tool/release/keys/` exist and are non-empty, and that `git status` shows nothing from the private folder.

```bash
git add tool/release/keys
git commit -m "chore(release): the public halves of the signing keys"
```

---

### Task 8: The Sparkle updater

**Files:**
- Create: `lib/update/sparkle_updater.dart`
- Test: `test/update/sparkle_updater_test.dart`
- Create: `macos/Runner/UpdaterBridge.swift`
- Modify: `macos/Runner/MainFlutterWindow.swift`
- Modify: `macos/Runner/Info.plist`
- Modify: `macos/Runner/Configs/AppInfo.xcconfig`
- Modify: `macos/Runner/Release.entitlements`
- Modify: `macos/Runner.xcodeproj/project.pbxproj` (the new Swift file, and the Sparkle package)

**Interfaces:**
- Consumes: `StateUpdater` (Task 5), `updateLog` (Task 4), `tool/release/keys/sparkle.pub` (Task 7).
- Produces:
  - `class SparkleUpdater extends StateUpdater` with `SparkleUpdater({MethodChannel channel})`.
  - The channel `moe.loaf.chat/updater`. Dart calls `start` and `restart`, no arguments. Native calls `state` with `{'state': 'idle' | 'preparing' | 'ready', 'version': String?}`.

- [ ] **Step 1: Write the failing Dart tests**

`test/update/sparkle_updater_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/updater.dart';
import 'package:loaf_native/update/sparkle_updater.dart';

const _channel = MethodChannel('moe.loaf.chat/updater');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  /// What the Swift side would send.
  Future<void> native(String state, [String? version]) =>
      messenger.handlePlatformMessage(
        _channel.name,
        _channel.codec.encodeMethodCall(
          MethodCall('state', {'state': state, 'version': version}),
        ),
        (_) {},
      );

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  SparkleUpdater updater() {
    final u = SparkleUpdater();
    addTearDown(u.dispose);
    return u;
  }

  test('it starts the native updater once it is listening', () async {
    updater();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['start']);
  });

  test('native states become update states', () async {
    final u = updater();
    await native('preparing');
    expect(u.state, isA<UpdatePreparing>());
    await native('ready', '0.1.2');
    expect((u.state as UpdateReady).version, '0.1.2');
    await native('idle');
    expect(u.state, isA<UpdateIdle>());
  });

  test('a state it does not know is idle', () async {
    final u = updater();
    await native('ready', '0.1.2');
    await native('something new');
    expect(u.state, isA<UpdateIdle>());
  });

  test('restart is passed on only when ready', () async {
    final u = updater();
    await u.restart();
    expect(calls, isNot(contains('restart')));
    await native('ready', '0.1.2');
    await u.restart();
    expect(calls, contains('restart'));
    expect((u.state as UpdateApplying).version, '0.1.2');
  });

  test('a restart the native side refuses leaves it ready', () async {
    final u = updater();
    await native('ready', '0.1.2');
    messenger.setMockMethodCallHandler(
      _channel,
      (_) async => throw PlatformException(code: 'no'),
    );
    await u.restart();
    expect(u.state, isA<UpdateReady>());
  });

  test('no native side at all is just idle', () async {
    messenger.setMockMethodCallHandler(_channel, null);
    final u = updater();
    await Future<void>.delayed(Duration.zero);
    expect(u.state, isA<UpdateIdle>());
  });

  test('a state arriving after dispose is dropped', () async {
    final u = SparkleUpdater();
    u.dispose();
    await native('ready', '0.1.2');
    expect(u.state, isA<UpdateIdle>());
  });
}
```

- [ ] **Step 2: Run to see them fail, then write the Dart side**

Run: `mise exec -- flutter test test/update/sparkle_updater_test.dart`
Expected: a compile failure.

`lib/update/sparkle_updater.dart`:

```dart
/// Updates the macOS app through Sparkle, which checks, downloads, verifies
/// and installs. Sparkle shows no windows of its own here: it reports over
/// a method channel, and the rail's notice is the only thing you see.
/// The other end is `macos/Runner/UpdaterBridge.swift`.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../ui/model/updater.dart';
import 'state_updater.dart';
import 'update_log.dart';

class SparkleUpdater extends StateUpdater {
  SparkleUpdater({
    MethodChannel channel = const MethodChannel('moe.loaf.chat/updater'),
  }) : _channel = channel {
    _channel.setMethodCallHandler(_onCall);
    // Only now: a state sent before anyone listens would be lost.
    unawaited(_start());
  }

  final MethodChannel _channel;

  Future<void> _start() async {
    try {
      await _channel.invokeMethod<void>('start');
    } catch (e) {
      updateLog('Sparkle did not start', e);
    }
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'state') return;
    final args = call.arguments;
    if (args is! Map) return;
    move(switch (args['state']) {
      'preparing' => const UpdatePreparing(),
      'ready' => UpdateReady(args['version'] as String?),
      _ => const UpdateIdle(),
    });
  }

  @override
  Future<void> restart() async {
    final ready = state;
    if (ready is! UpdateReady) return;
    move(UpdateApplying(ready.version));
    try {
      await _channel.invokeMethod<void>('restart');
    } catch (e, s) {
      updateLog('Sparkle did not restart the app', e, s);
      move(ready);
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
```

Run: `mise exec -- flutter test test/update/sparkle_updater_test.dart`
Expected: all pass.

- [ ] **Step 3: Add Sparkle to the Runner**

In Xcode: File › Add Package Dependencies, `https://github.com/sparkle-project/Sparkle`, "Up to Next Major" from the version used in Task 7, product `Sparkle` added to the `Runner` target. Without Xcode's UI, add to `project.pbxproj` an `XCRemoteSwiftPackageReference`, an `XCSwiftPackageProductDependency`, a `PBXBuildFile` for it in the Runner's Frameworks phase, and list them under the project's `packageReferences` and the target's `packageProductDependencies`. Follow how the project's existing Flutter package reference is written.

Add `UpdaterBridge.swift` to the Runner group and its Sources build phase the same way `MainFlutterWindow.swift` is listed.

- [ ] **Step 4: Write the Swift bridge**

Open Sparkle's `SPUUserDriver.h` and `SPUUpdaterDelegate.h` first. If a selector below differs from the header, the header wins.

`macos/Runner/UpdaterBridge.swift`:

```swift
import Cocoa
import FlutterMacOS
import Sparkle

/// Sparkle, with no windows of its own. Sparkle asks its user driver what
/// to show at each step; this one shows nothing and answers for itself,
/// reporting to Dart instead, where the rail's notice is the only UI.
/// The other end is `lib/update/sparkle_updater.dart`.
final class UpdaterBridge: NSObject, SPUUpdaterDelegate, SPUUserDriver {
  private let channel: FlutterMethodChannel
  private var updater: SPUUpdater?

  /// Set once an update is staged: either Sparkle's quiet install-on-quit
  /// path, or its ready-to-relaunch prompt. Calling it installs and relaunches.
  private var install: (() -> Void)?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "moe.loaf.chat/updater", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "start":
        self?.start()
        result(nil)
      case "restart":
        guard let install = self?.install else {
          result(FlutterError(code: "not-ready", message: nil, details: nil))
          return
        }
        install()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func start() {
    guard updater == nil else { return }
    let sparkle = SPUUpdater(
      hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
    do {
      try sparkle.start()
      updater = sparkle
      sparkle.checkForUpdatesInBackground()
    } catch {
      NSLog("[loaf update] Sparkle did not start: \(error)")
    }
  }

  private func send(_ state: String, version: String? = nil) {
    channel.invokeMethod("state", arguments: ["state": state, "version": version])
  }

  private func staged(_ item: SUAppcastItem?, install: @escaping () -> Void) {
    self.install = install
    send("ready", version: item?.displayVersionString)
  }

  private var found: SUAppcastItem?

  // MARK: SPUUpdaterDelegate

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    found = item
    if install == nil { send("preparing") }
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
    if install == nil { send("idle") }
  }

  func updater(
    _ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error
  ) {
    NSLog("[loaf update] download failed: \(error)")
    if install == nil { send("idle") }
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    if install == nil { send("idle") }
  }

  /// The quiet path: downloaded and verified, waiting for the app to quit.
  /// Returning true keeps the timing ours; the block restarts on request.
  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    staged(item, install: immediateInstallHandler)
    return true
  }

  // MARK: SPUUserDriver — every prompt answered without showing anything.

  func show(
    _ request: SPUUpdatePermissionRequest,
    reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

  func showUpdateFound(
    with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    found = appcastItem
    reply(.install)
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }

  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    NSLog("[loaf update] \(error)")
    acknowledgement()
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {}

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

  func showDownloadDidReceiveData(ofLength length: UInt64) {}

  func showDownloadDidStartExtractingUpdate() {}

  func showExtractionReceivedProgress(_ progress: Double) {}

  /// The other path to staged: Sparkle asks before relaunching. The answer
  /// waits for the rail's restart.
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    staged(found, install: { reply(.install) })
  }

  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {}

  func showUpdateInstalledAndRelaunched(
    _ relaunched: Bool, acknowledgement: @escaping () -> Void
  ) {
    acknowledgement()
  }

  func showUpdateInFocus() {}

  func dismissUpdateInstallation() {}
}
```

In `MainFlutterWindow.swift`, keep the bridge alive for the window's life:

```swift
  private var updaterBridge: UpdaterBridge?
```

and, after `RegisterGeneratedPlugins(registry: flutterViewController)`:

```swift
    updaterBridge = UpdaterBridge(
      messenger: flutterViewController.engine.binaryMessenger)
```

The bridge is inert until Dart calls `start`, which only a release build from the pipeline does (Task 9).

- [ ] **Step 5: Info.plist, the key, and the sandbox**

`AppInfo.xcconfig`, with the one line from `tool/release/keys/sparkle.pub`:

```
// Sparkle verifies every download against this. Its private half signs
// releases in CI; see tool/release/keygen.sh.
SPARKLE_PUBLIC_KEY = <the contents of tool/release/keys/sparkle.pub>
```

`Info.plist`, inside the top-level `<dict>`:

```xml
	<key>SUFeedURL</key>
	<string>https://get.loaf.moe/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>$(SPARKLE_PUBLIC_KEY)</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
	<key>SUAutomaticallyUpdate</key>
	<true/>
	<key>SUScheduledCheckInterval</key>
	<integer>21600</integer>
	<key>SUEnableInstallerLauncherService</key>
	<true/>
```

`Release.entitlements`, inside the `<dict>`:

```xml
	<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
	<array>
		<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spks</string>
		<string>$(PRODUCT_BUNDLE_IDENTIFIER)-spki</string>
	</array>
```

- [ ] **Step 6: Verify the build**

Run: `mise exec -- flutter build macos --release`
Expected: succeeds.

Run: `ls "build/macos/Build/Products/Release/Loaf Chat.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"`
Expected: `Installer.xpc` is listed.

Run: `lipo -archs "build/macos/Build/Products/Release/Loaf Chat.app/Contents/Frameworks/libflutter_vodozemac.dylib"`
Expected: `x86_64 arm64`. This settles the spec's open point about a universal vodozemac. If only one architecture is listed, stop and report: the DMG would not run on the other.

Run: `/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "build/macos/Build/Products/Release/Loaf Chat.app/Contents/Info.plist"`
Expected: the key from `sparkle.pub`.

Run: `mise exec -- flutter build macos --debug` and `mise exec -- flutter test`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/update/sparkle_updater.dart test/update/sparkle_updater_test.dart macos
git commit -m "feat(update): macOS updates through Sparkle, shown in the rail"
```

---

### Task 9: Picking the backend

**Files:**
- Create: `lib/update/build_info.dart`
- Create: `lib/update/pick_updater.dart`
- Modify: `lib/main.dart`
- Test: `test/update/pick_updater_test.dart`

**Interfaces:**
- Consumes: every backend (Tasks 5, 6, 8); `ed25519Check`, `fetchRelease` (Task 4); `SessionRoot(updater:)` (Task 3); `tool/release/keys/appimage.pub` (Task 7).
- Produces:
  - `const int buildNumber` from `--dart-define=LOAF_BUILD`, 0 when absent.
  - `final Uri latestFeed` (`https://get.loaf.moe/latest.json`), `const String appImagePublicKey`.
  - `enum UpdaterKind { none, sparkle, flatpak, appImage }`
  - `UpdaterKind chooseUpdater({required bool release, required int build, required TargetPlatform platform, required Map<String, String> environment})`
  - `Updater pickUpdater()`

- [ ] **Step 1: Write the failing tests**

`test/update/pick_updater_test.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/update/pick_updater.dart';

UpdaterKind _choose({
  bool release = true,
  int build = 412,
  TargetPlatform platform = TargetPlatform.linux,
  Map<String, String> environment = const {},
}) => chooseUpdater(
  release: release,
  build: build,
  platform: platform,
  environment: environment,
);

const _flatpak = {'FLATPAK_ID': 'moe.loaf.chat'};
const _appImage = {'APPIMAGE': '/home/me/Loaf-Chat.AppImage'};

void main() {
  test('macOS uses Sparkle', () {
    expect(_choose(platform: TargetPlatform.macOS), UpdaterKind.sparkle);
  });

  test('inside a Flatpak, the portal', () {
    expect(_choose(environment: _flatpak), UpdaterKind.flatpak);
  });

  test('inside an AppImage, our own', () {
    expect(_choose(environment: _appImage), UpdaterKind.appImage);
  });

  test('an AppImage started from inside a Flatpak is still a Flatpak', () {
    expect(
      _choose(environment: {..._flatpak, ..._appImage}),
      UpdaterKind.flatpak,
    );
  });

  test('a bare Linux binary has none', () {
    expect(_choose(), UpdaterKind.none);
    expect(_choose(environment: {'APPIMAGE': ''}), UpdaterKind.none);
  });

  test('Windows has none yet, and phones never', () {
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      expect(_choose(platform: platform), UpdaterKind.none);
    }
  });

  test('a debug or profile build has none, wherever it runs', () {
    expect(
      _choose(release: false, platform: TargetPlatform.macOS),
      UpdaterKind.none,
    );
    expect(_choose(release: false, environment: _appImage), UpdaterKind.none);
  });

  test('a release build made by hand has none', () {
    // No build number means it did not come from the pipeline. With an
    // updater it would see every published build as newer than itself.
    expect(_choose(build: 0, platform: TargetPlatform.macOS), UpdaterKind.none);
    expect(_choose(build: 0, environment: _appImage), UpdaterKind.none);
    expect(_choose(build: 0, environment: _flatpak), UpdaterKind.none);
  });
}
```

- [ ] **Step 2: Run to see them fail**

Run: `mise exec -- flutter test test/update/pick_updater_test.dart`
Expected: a compile failure.

- [ ] **Step 3: Write the build info and the chooser**

`lib/update/build_info.dart`, with the one line from `tool/release/keys/appimage.pub`:

```dart
/// What this build is, and where it looks for the next one.
library;

/// The release pipeline passes `--dart-define=LOAF_BUILD=<commit count>`.
/// Zero means a build made by hand, which nothing updates.
const buildNumber = int.fromEnvironment('LOAF_BUILD');

final latestFeed = Uri.parse('https://get.loaf.moe/latest.json');

/// The release key's public half. Its private half signs `latest.json` in
/// CI; see tool/release/keygen.sh.
const appImagePublicKey = '<the contents of tool/release/keys/appimage.pub>';
```

`lib/update/pick_updater.dart`:

```dart
/// Which updater this copy of the app gets, decided once at launch by how
/// it was installed.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../ui/model/updater.dart';
import 'appimage_updater.dart';
import 'build_info.dart';
import 'dbus_flatpak_portal.dart';
import 'ed25519.dart';
import 'flatpak_updater.dart';
import 'release_feed.dart';
import 'sparkle_updater.dart';

enum UpdaterKind { none, sparkle, flatpak, appImage }

UpdaterKind chooseUpdater({
  required bool release,
  required int build,
  required TargetPlatform platform,
  required Map<String, String> environment,
}) {
  if (!release || build == 0) return UpdaterKind.none;
  bool has(String name) => (environment[name] ?? '').isNotEmpty;
  return switch (platform) {
    TargetPlatform.macOS => UpdaterKind.sparkle,
    // Flatpak first: its sandbox is what is really running.
    TargetPlatform.linux when has('FLATPAK_ID') => UpdaterKind.flatpak,
    TargetPlatform.linux when has('APPIMAGE') => UpdaterKind.appImage,
    _ => UpdaterKind.none,
  };
}

/// Call after vodozemac is initialised: the AppImage updater verifies with it.
Updater pickUpdater() {
  final environment = Platform.environment;
  switch (chooseUpdater(
    release: kReleaseMode,
    build: buildNumber,
    platform: defaultTargetPlatform,
    environment: environment,
  )) {
    case UpdaterKind.none:
      return const NoUpdater();
    case UpdaterKind.sparkle:
      return SparkleUpdater();
    case UpdaterKind.flatpak:
      final updater = FlatpakUpdater(
        portal: DbusFlatpakPortal(),
        version: () async {
          final client = http.Client();
          try {
            return (await fetchRelease(client, latestFeed)).version;
          } finally {
            client.close();
          }
        },
      );
      unawaited(updater.start());
      return updater;
    case UpdaterKind.appImage:
      return AppImageUpdater(
        appImage: File(environment['APPIMAGE']!),
        build: buildNumber,
        feed: latestFeed,
        verify: ed25519Check(appImagePublicKey),
      )..start();
  }
}
```

- [ ] **Step 4: Wire it into the app**

In `lib/main.dart`, import `ui/model/updater.dart` and `update/pick_updater.dart`, and add beside `newRooms`:

```dart
/// What replaces this copy of the app with a newer one; null plays the
/// mock's. Lives as long as the app.
Updater? updater;
```

In `main()`, in the real branch, after `MatrixSession.open` (which initialises vodozemac):

```dart
    updater = pickUpdater();
```

And pass it on:

```dart
          child: SessionRoot(session: session, rooms: newRooms, updater: updater),
```

- [ ] **Step 5: Run everything**

Run: `mise exec -- flutter analyze` — Expected: no issues.
Run: `mise exec -- flutter test` — Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/update lib/main.dart test/update/pick_updater_test.dart
git commit -m "feat(update): the app picks its updater by how it was installed"
```

---

### Task 10: Packaging and the release workflow

**Files:**
- Create: `linux/packaging/moe.loaf.chat.desktop`
- Create: `linux/packaging/moe.loaf.chat.metainfo.xml`
- Create: `linux/packaging/moe.loaf.chat.yml`
- Create: `tool/release/macos.sh`
- Create: `tool/release/appimage.sh`
- Create: `tool/release/flatpak.sh`
- Create: `tool/release/pages.sh`
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: the names from Task 1; `tool/release/keys/flatpak.asc` (Task 7); the secrets Task 11 enters.
- Produces: on a `v*` tag, a GitHub Release with `Loaf-Chat-<version>.dmg` and `Loaf-Chat-<version>-x86_64.AppImage`, and a `gh-pages` branch holding `appcast.xml`, `latest.json`, `repo/`, `loaf-chat.flatpakref`, `CNAME`.
- Secrets read (environment `release`): `MACOS_CERTIFICATE_P12` (base64), `MACOS_CERTIFICATE_PASSWORD`, `NOTARY_KEY_P8` (base64), `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `SPARKLE_PRIVATE_KEY`, `APPIMAGE_PRIVATE_KEY`, `FLATPAK_GPG_PRIVATE_KEY`.

None of this can be unit-tested. Its test is Task 12. Make every script `set -euo pipefail` and `chmod +x`.

- [ ] **Step 1: The Linux desktop files**

`linux/packaging/moe.loaf.chat.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Loaf Chat
Comment=A Matrix client for loaf.moe
Exec=loaf-chat
Icon=moe.loaf.chat
Categories=Network;InstantMessaging;Chat;
StartupWMClass=moe.loaf.chat
Terminal=false
```

`linux/packaging/moe.loaf.chat.metainfo.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>moe.loaf.chat</id>
  <name>Loaf Chat</name>
  <summary>A Matrix client for loaf.moe</summary>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>AGPL-3.0-only</project_license>
  <description>
    <p>A Matrix client for loaf.moe, shaped like a place you hang out.</p>
  </description>
  <launchable type="desktop-id">moe.loaf.chat.desktop</launchable>
  <url type="homepage">https://github.com/Loaf-moe/loaf-chat</url>
</component>
```

- [ ] **Step 2: The Flatpak manifest**

Permissions are declared once, calls included: the portal refuses an in-app update that adds one. `linux/packaging/moe.loaf.chat.yml`:

```yaml
# Packages the Flutter bundle CI already built; nothing compiles in here.
app-id: moe.loaf.chat
runtime: org.freedesktop.Platform
runtime-version: '25.08'
sdk: org.freedesktop.Sdk
command: loaf-chat
finish-args:
  - --share=network
  - --share=ipc
  - --socket=wayland
  - --socket=fallback-x11
  - --device=dri
  # Calls: microphone, speakers and camera. Declared before calls ship,
  # because a release that adds a permission cannot update in-app.
  - --socket=pulseaudio
  - --device=all
modules:
  - name: loaf-chat
    buildsystem: simple
    build-commands:
      - mkdir -p /app/loaf-chat /app/bin
      - cp -r bundle/. /app/loaf-chat/
      - ln -s /app/loaf-chat/loaf-chat /app/bin/loaf-chat
      - install -Dm644 moe.loaf.chat.desktop /app/share/applications/moe.loaf.chat.desktop
      - install -Dm644 moe.loaf.chat.metainfo.xml /app/share/metainfo/moe.loaf.chat.metainfo.xml
      - install -Dm644 app_icon_512.png /app/share/icons/hicolor/512x512/apps/moe.loaf.chat.png
    sources:
      - type: dir
        path: ../../build/linux/x64/release/bundle
        dest: bundle
      - type: file
        path: moe.loaf.chat.desktop
      - type: file
        path: moe.loaf.chat.metainfo.xml
      - type: file
        path: ../../macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png
```

If `25.08` is no longer the current freedesktop runtime, use the current one here and in the workflow's container image.

- [ ] **Step 3: `tool/release/macos.sh`**

```bash
#!/usr/bin/env bash
# Signs the macOS release build with Developer ID, packs a DMG, notarizes
# it, and writes Sparkle's feed. Run on macOS after `flutter build macos`.
# usage: macos.sh <version> <out dir>
set -euo pipefail

version="$1"; out="$2"
app="build/macos/Build/Products/Release/Loaf Chat.app"
identity="Developer ID Application: CHRISTOPHER ETIENNE THOMAS (6W2A5N37N3)"
sparkle_version="${SPARKLE_VERSION:-2.8.0}"
work="$(mktemp -d)"
mkdir -p "$out"

# A keychain of our own, so codesign can use the certificate unattended.
keychain="$work/release.keychain-db"
security create-keychain -p "" "$keychain"
security set-keychain-settings "$keychain"
security unlock-keychain -p "" "$keychain"
echo "$MACOS_CERTIFICATE_P12" | base64 --decode > "$work/certificate.p12"
security import "$work/certificate.p12" -k "$keychain" \
  -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" login.keychain-db

# The entitlements as Xcode expanded them: the file in the repo still has
# $(PRODUCT_BUNDLE_IDENTIFIER) in it, which codesign would take literally.
codesign -d --entitlements "$work/app.entitlements" --xml "$app"

sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }

# Inside out. Sparkle's helpers first, as its sandboxing guide orders them.
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
find "$app/Contents/Frameworks" -depth \( -name '*.dylib' -o -name '*.framework' \) -print0 \
  | while IFS= read -r -d '' item; do sign "$item"; done
sign --entitlements "$work/app.entitlements" "$app"
codesign --verify --deep --strict "$app"

stage="$work/dmg"; mkdir "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
dmg="$out/Loaf-Chat-$version.dmg"
hdiutil create -volname "Loaf Chat" -srcfolder "$stage" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"

echo "$NOTARY_KEY_P8" | base64 --decode > "$work/notary.p8"
xcrun notarytool submit "$dmg" --key "$work/notary.p8" \
  --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
# Fails unless the notary accepted it, which is the check we want.
xcrun stapler staple "$dmg"

mkdir "$work/sparkle"
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" \
  | tar -xJ -C "$work/sparkle"
feed="$work/feed"; mkdir "$feed"
cp "$dmg" "$feed/"
echo "$SPARKLE_PRIVATE_KEY" | "$work/sparkle/bin/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "https://github.com/Loaf-moe/loaf-chat/releases/download/v$version/" \
  -o "$out/appcast.xml" "$feed"
```

- [ ] **Step 4: `tool/release/appimage.sh`**

```bash
#!/usr/bin/env bash
# Packs the Linux bundle as an AppImage and writes the signed latest.json.
# usage: appimage.sh <version> <build> <out dir>
set -euo pipefail

version="$1"; build="$2"; out="$3"
bundle="build/linux/x64/release/bundle"
work="$(mktemp -d)"
appdir="$work/Loaf-Chat.AppDir"
mkdir -p "$out" "$appdir"

cp -r "$bundle"/. "$appdir/"
cp linux/packaging/moe.loaf.chat.desktop "$appdir/"
cp macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png "$appdir/moe.loaf.chat.png"
cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
exec "$(dirname "$(readlink -f "$0")")/loaf-chat" "$@"
EOF
chmod +x "$appdir/AppRun"

curl -fsSL -o "$work/appimagetool" \
  https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$work/appimagetool"
name="Loaf-Chat-$version-x86_64.AppImage"
# Runners have no FUSE, so the tool unpacks itself to run.
ARCH=x86_64 "$work/appimagetool" --appimage-extract-and-run "$appdir" "$out/$name"

sha="$(sha256sum "$out/$name" | cut -d' ' -f1)"
size="$(stat -c %s "$out/$name")"
# Exactly Release.signedText in lib/update/release_feed.dart: no last newline.
printf 'loaf-chat-appimage\n%s\n%s\n%s' "$version" "$build" "$sha" > "$work/signed.txt"
echo "$APPIMAGE_PRIVATE_KEY" > "$work/key.pem"
signature="$(openssl pkeyutl -sign -inkey "$work/key.pem" -rawin -in "$work/signed.txt" | base64 -w0)"

jq -n --arg version "$version" --argjson build "$build" \
  --arg url "https://github.com/Loaf-moe/loaf-chat/releases/download/v$version/$name" \
  --arg sha256 "$sha" --argjson size "$size" --arg signature "$signature" \
  '{version: $version, build: $build,
    appimage: {url: $url, sha256: $sha256, size: $size, signature: $signature}}' \
  > "$out/latest.json"
```

- [ ] **Step 5: `tool/release/flatpak.sh`**

```bash
#!/usr/bin/env bash
# Commits the Linux bundle to the Flatpak repo, signed, keeping three builds.
# usage: flatpak.sh <version> <repo dir>
set -euo pipefail

version="$1"; repo="$2"
work="$(mktemp -d)"

echo "$FLATPAK_GPG_PRIVATE_KEY" | gpg --batch --import
key="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')"

flatpak-builder --force-clean --disable-rofiles-fuse \
  --repo="$repo" --default-branch=stable \
  --gpg-sign="$key" --subject="Loaf Chat $version" \
  "$work/build" linux/packaging/moe.loaf.chat.yml
# This build and the two before it.
flatpak build-update-repo --prune --prune-depth=2 --gpg-sign="$key" \
  --title="Loaf Chat" "$repo"
```

- [ ] **Step 6: `tool/release/pages.sh`**

```bash
#!/usr/bin/env bash
# Lays out what get.loaf.moe serves.
# usage: pages.sh <dist dir with appcast.xml, latest.json, repo/> <pages dir>
set -euo pipefail

dist="$1"; pages="$2"
mkdir -p "$pages"
cp -r "$dist/repo" "$pages/repo"
cp "$dist/appcast.xml" "$dist/latest.json" "$pages/"
echo "get.loaf.moe" > "$pages/CNAME"
# Without this Pages runs Jekyll, which drops the repo's dot-prefixed files.
touch "$pages/.nojekyll"

cat > "$pages/loaf-chat.flatpakref" <<EOF
[Flatpak Ref]
Name=moe.loaf.chat
Branch=stable
Title=Loaf Chat
Url=https://get.loaf.moe/repo/
IsRuntime=false
RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo
GPGKey=$(gpg --dearmor < tool/release/keys/flatpak.asc | base64 -w0)
EOF
```

- [ ] **Step 7: The workflow**

`.github/workflows/release.yml`:

```yaml
# Pushing a tag like v0.1.0, on main, is the whole release.
name: release

on:
  push:
    tags: ['v*']

permissions:
  contents: write

concurrency: release

jobs:
  version:
    runs-on: ubuntu-latest
    outputs:
      name: ${{ steps.version.outputs.name }}
      build: ${{ steps.version.outputs.build }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: version
        run: |
          git fetch origin main
          git merge-base --is-ancestor "$GITHUB_SHA" origin/main \
            || { echo "::error::the tag is not on main"; exit 1; }
          name="${GITHUB_REF_NAME#v}"
          [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || { echo "::error::tags look like v1.2.3"; exit 1; }
          echo "name=$name" >> "$GITHUB_OUTPUT"
          # Every updater compares this, so it only ever goes up.
          echo "build=$(git rev-list --count "$GITHUB_SHA")" >> "$GITHUB_OUTPUT"

  macos:
    needs: version
    runs-on: macos-latest
    environment: release
    steps:
      - uses: actions/checkout@v4
      - uses: jdx/mise-action@v2
      - run: >
          mise exec -- flutter build macos --release
          --build-name=${{ needs.version.outputs.name }}
          --build-number=${{ needs.version.outputs.build }}
          --dart-define=LOAF_BUILD=${{ needs.version.outputs.build }}
      - run: tool/release/macos.sh "${{ needs.version.outputs.name }}" dist
        env:
          MACOS_CERTIFICATE_P12: ${{ secrets.MACOS_CERTIFICATE_P12 }}
          MACOS_CERTIFICATE_PASSWORD: ${{ secrets.MACOS_CERTIFICATE_PASSWORD }}
          NOTARY_KEY_P8: ${{ secrets.NOTARY_KEY_P8 }}
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER_ID: ${{ secrets.NOTARY_ISSUER_ID }}
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
      - uses: actions/upload-artifact@v4
        with:
          name: macos
          path: dist/

  linux:
    needs: version
    # The oldest runner, for the oldest glibc: the AppImage runs on whatever
    # the tester has.
    runs-on: ubuntu-22.04
    environment: release
    steps:
      - uses: actions/checkout@v4
      - run: |
          sudo apt-get update
          sudo apt-get install -y clang cmake ninja-build pkg-config \
            libgtk-3-dev liblzma-dev libstdc++-12-dev jq
      - uses: jdx/mise-action@v2
      - run: >
          mise exec -- flutter build linux --release
          --build-name=${{ needs.version.outputs.name }}
          --build-number=${{ needs.version.outputs.build }}
          --dart-define=LOAF_BUILD=${{ needs.version.outputs.build }}
      - run: >
          tool/release/appimage.sh "${{ needs.version.outputs.name }}"
          "${{ needs.version.outputs.build }}" dist
        env:
          APPIMAGE_PRIVATE_KEY: ${{ secrets.APPIMAGE_PRIVATE_KEY }}
      # Tarred: artifacts drop the executable bit.
      - run: tar -cf dist/bundle.tar -C build/linux/x64/release bundle
      - uses: actions/upload-artifact@v4
        with:
          name: linux
          path: dist/

  flatpak:
    needs: [version, linux]
    runs-on: ubuntu-latest
    environment: release
    container:
      image: ghcr.io/flathub-infra/flatpak-github-actions:freedesktop-25.08
      options: --privileged
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: linux
          path: dist
      - run: |
          mkdir -p build/linux/x64/release
          tar -xf dist/bundle.tar -C build/linux/x64/release
          # The repo so far, so this build lands on top of the last ones.
          if git clone --depth 1 --branch gh-pages \
              "https://github.com/${GITHUB_REPOSITORY}.git" pages-before; then
            mv pages-before/repo repo
          fi
      - run: tool/release/flatpak.sh "${{ needs.version.outputs.name }}" repo
        env:
          FLATPAK_GPG_PRIVATE_KEY: ${{ secrets.FLATPAK_GPG_PRIVATE_KEY }}
      - run: tar -cf repo.tar repo
      - uses: actions/upload-artifact@v4
        with:
          name: flatpak
          path: repo.tar

  publish:
    needs: [version, macos, linux, flatpak]
    runs-on: ubuntu-latest
    environment: release
    env:
      GH_TOKEN: ${{ github.token }}
      VERSION: ${{ needs.version.outputs.name }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          path: artifacts
      - name: Release assets first
        run: |
          gh release view "$GITHUB_REF_NAME" >/dev/null 2>&1 \
            || gh release create "$GITHUB_REF_NAME" --draft \
                 --title "Loaf Chat $VERSION" --generate-notes
          gh release upload "$GITHUB_REF_NAME" --clobber \
            artifacts/macos/*.dmg artifacts/linux/*.AppImage
          # Public before any feed names them: a feed never points at a
          # file that is not there.
          gh release edit "$GITHUB_REF_NAME" --draft=false
      - name: Feeds last
        run: |
          mkdir dist
          tar -xf artifacts/flatpak/repo.tar -C dist
          cp artifacts/macos/appcast.xml artifacts/linux/latest.json dist/
          tool/release/pages.sh dist pages
          cd pages
          # One commit, replaced each time: the branch keeps no history.
          git init -b gh-pages
          git add -A
          git -c user.name="loaf chat releases" -c user.email="releases@loaf.moe" \
            commit -q -m "Loaf Chat $VERSION"
          git push --force \
            "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" gh-pages
```

- [ ] **Step 8: Lint and commit**

Run: `bash -n tool/release/macos.sh tool/release/appimage.sh tool/release/flatpak.sh tool/release/pages.sh`
Expected: no output.

If `actionlint` is installed, run `actionlint .github/workflows/release.yml`. Expected: no findings.

```bash
git add linux/packaging tool/release .github
git commit -m "feat(release): a tag builds, signs and publishes every desktop artifact"
```

---

### Task 11: One-time setup (Chris)

**This task enters secrets and changes account settings. An agent stops here and hands over.**

- [ ] **Step 1: The `release` environment**

On GitHub: Settings › Environments › New environment, `release`. Under "Deployment branches and tags" choose "Selected branches and tags" and add the tag rule `v*`. Nothing else may use its secrets.

- [ ] **Step 2: The signing keys from Task 7**

From the repo folder, in Nushell:

```bash
open --raw ~/loaf-chat-release-keys/appimage-private.pem | gh secret set APPIMAGE_PRIVATE_KEY --env release
```

```bash
open --raw ~/loaf-chat-release-keys/sparkle-private.txt | gh secret set SPARKLE_PRIVATE_KEY --env release
```

```bash
open --raw ~/loaf-chat-release-keys/flatpak-private.asc | gh secret set FLATPAK_GPG_PRIVATE_KEY --env release
```

- [ ] **Step 3: The Developer ID certificate**

In Keychain Access, export "Developer ID Application: CHRISTOPHER ETIENNE THOMAS (6W2A5N37N3)" with its private key as `developer-id.p12`, with a password. Then:

```bash
open --raw developer-id.p12 | encode base64 | gh secret set MACOS_CERTIFICATE_P12 --env release
```

```bash
gh secret set MACOS_CERTIFICATE_PASSWORD --env release
```

The second command prompts for the password. Delete `developer-id.p12` afterwards.

- [ ] **Step 4: The notarization key**

In App Store Connect: Users and Access › Integrations › App Store Connect API › Team Keys, create a key with the Developer role. Download the `.p8` (once only), and note the Key ID and the Issuer ID.

```bash
open --raw AuthKey.p8 | encode base64 | gh secret set NOTARY_KEY_P8 --env release
```

```bash
gh secret set NOTARY_KEY_ID --env release
```

```bash
gh secret set NOTARY_ISSUER_ID --env release
```

- [ ] **Step 5: DNS and Pages**

- Add a DNS record: `get.loaf.moe` CNAME `loaf-moe.github.io`.
- Pages has no branch to serve until the first release creates `gh-pages`. After Task 12's first tag: Settings › Pages › Deploy from a branch, `gh-pages`, `/`; custom domain `get.loaf.moe`; enforce HTTPS once the certificate is issued.

- [ ] **Step 6: Confirm**

Run: `gh secret list --env release`
Expected: eight secrets, the names in Task 10's Interfaces.

---

### Task 12: Install instructions, and the rehearsal

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-09-29-desktop-updates-design.md` (record what the rehearsal found)

The rehearsal is the spec's acceptance test. It needs a Mac and a Linux desktop with Flatpak. Nobody outside gets a link until it passes, and until Windows (pieces 2 and 3 of the spec) is done too.

- [ ] **Step 1: Install instructions**

Replace the README's Flutter boilerplate ("Getting Started" to the end, keeping "Licence") with:

```markdown
## Installing

Loaf Chat updates itself on every computer it is installed on.

- **macOS:** download the `.dmg` from the
  [latest release](https://github.com/Loaf-moe/loaf-chat/releases/latest),
  open it, and drag Loaf Chat to Applications.
- **Linux, Flatpak:** `flatpak install https://get.loaf.moe/loaf-chat.flatpakref`
- **Linux, AppImage:** download the `.AppImage` from the latest release,
  mark it executable, and run it. Keep it somewhere you can write to, or it
  cannot update itself.

Phones get Loaf Chat through TestFlight.

## Releasing

Push a tag like `v0.1.0` that sits on `main`. `.github/workflows/release.yml`
does the rest. The signing keys are made by `tool/release/keygen.sh`.
```

Commit: `git commit -am "docs: how to install Loaf Chat, and how to release it"`. Merge to `main` and push.

- [ ] **Step 2: The first release**

```bash
git tag v0.1.0
```

```bash
git push origin v0.1.0
```

Watch: `gh run watch`. Expected: all five jobs pass. Then finish Task 11 Step 5 (Pages), and check:

- `curl -fsS https://get.loaf.moe/latest.json` shows `"version":"0.1.0"`.
- `curl -fsS https://get.loaf.moe/appcast.xml` names `Loaf-Chat-0.1.0.dmg`.
- `gh release view v0.1.0` lists the DMG and the AppImage.

A job that fails is fixed on `main` and released as `v0.1.1`, and so on. Never move a tag.

- [ ] **Step 3: Install 0.1.0 three ways, and sign in on each**

- macOS: from the DMG. Gatekeeper opens it without a warning.
- Linux: `flatpak install https://get.loaf.moe/loaf-chat.flatpakref`.
- Linux: the AppImage, in `~/Applications`.

On each, sign in with SSO. On Flatpak this settles the spec's open point about the loopback listener in the sandbox. No copy shows an update notice.

- [ ] **Step 4: The second release**

Make any small visible change on `main`, then tag and push the next version. Leave all three copies running.

- [ ] **Step 5: Watch each copy update**

Relaunch each copy (the first check is shortly after launch), and within a few minutes expect the rail notice naming the new version. Press restart. Expected: the app comes back as the new version, still signed in.

Record for each: did the notice appear, did restart work, and on Flatpak, **did the system show a permission dialog before installing?** That settles the spec's last open point.

Also, once: dismiss with "later" on one copy, quit it, and start it again. Expected: it starts as the new version.

- [ ] **Step 6: Write down what it found**

In the spec, move each "Not verified" line into "Verified" with what was seen, or into a new "What the rehearsal found" section if something differed. If the Flatpak portal prompts, say so under "Linux, Flatpak" in one line.

```bash
git add docs/superpowers/specs/2026-09-29-desktop-updates-design.md
git commit -m "docs(updates): what the release rehearsal found"
```
