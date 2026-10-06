# 日本 Theme Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A seasonal 日本 theme (dark plum, drifting sakura, a little Shinkansen) that takes over from Oct 16 to Nov 6, plus an appearance section in settings to pick Loaf Dark or 日本 and to turn easter eggs off.

**Architecture:** An `AppearanceController` (ChangeNotifier, saved to a JSON file) resolves the effective theme from the pick, the easter-egg flag and today's date. `LoafTokens` gains a `decor` field so the petal and train widgets read the theme, not the controller. An `AppearanceScope` above `MaterialApp` lets the settings dialog find the controller.

**Tech Stack:** Flutter 3.47.5 (run through `mise exec -- flutter …`), `path_provider` (already a dependency), `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-10-05-nihon-theme-design.md`

## Global Constraints

- Run Flutter as `mise exec -- flutter <cmd>` from `/Users/faore/code/loaf-native`. The shell is Nushell: use `;` not `&&`.
- **Do not commit.** The working tree holds the user's unrelated uncommitted work (including `lib/ui/settings/settings_page.dart`). Leave all changes unstaged; the controller reviews diffs.
- No new dependencies.
- Theme labels are exactly `Loaf Dark` and `日本`. Other UI copy is lowercase-first, like the rest of settings (`easter eggs`, `theme`).
- Season window: Oct 16 00:00 through Nov 6 23:59 local time, every year, inclusive.
- Comment the *why*, not the *what*; match the surrounding doc-comment density (every file opens with a `///` library comment).
- **Timers in widget tests:** `AppearanceController` always holds a midnight `Timer`. `testWidgets` fails on a pending Timer *before* `addTearDown` runs, so every `testWidgets` that creates a controller must end its body with `await tester.pumpWidget(const SizedBox()); controller.dispose();` (unmount first, then dispose). Plain `test()`s may use `addTearDown(c.dispose)`.
- `mise exec -- dart format lib test` before finishing each task; `mise exec -- flutter analyze` must be clean for files you touched.

## Review Focus

1. **Settings file missing, unreadable or hand-edited** — the app still starts with Loaf Dark and easter eggs on; it never crashes on launch. (Task 1: missing/garbage/unknown-theme tests.)
2. **Saving fails** (read-only disk) — the choice still applies for this run, with no unhandled async error. (Task 1: throwing-store test.)
3. **App left open across midnight Oct 15→16** — it switches to 日本 without a restart. (Task 1: midnight timer test.)
4. **Reduced motion turned on** — no petals and no running ticker; the train is still. (Task 3: transient-callback test.)
5. **Decor under Loaf Dark** — no extra height above the composer and nothing painted. (Task 3: Loaf Dark test.)

---

### Task 1: Appearance model

**Files:**
- Create: `lib/ui/theme/appearance.dart`
- Test: `test/appearance_test.dart`

**Interfaces:**
- Produces: `enum LoafThemeId { loafDark, nihon }` with `String label`; `bool inNihonSeason(DateTime)`; `AppearanceSettings({LoafThemeId theme, bool easterEggs})`; `AppearanceStore` (`load()`, `save()`); `MemoryAppearanceStore([AppearanceSettings?])` with public `saved`; `FileAppearanceStore(File)` and `static Future<FileAppearanceStore> inSupportDirectory()`; `AppearanceController({required AppearanceStore store, AppearanceSettings settings, DateTime Function() clock})` with `chosen`, `easterEggs`, `effective`, `seasonOverrides`, `choose(LoafThemeId)`, `setEasterEggs(bool)`, `static Future<AppearanceController> load(AppearanceStore, {DateTime Function() clock})`; `AppearanceScope({required AppearanceController controller, required Widget child})` with `static AppearanceController? maybeOf(BuildContext)`.

- [ ] **Step 1: Write the failing tests** — `test/appearance_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/theme/appearance.dart';

class _BrokenStore implements AppearanceStore {
  @override
  Future<AppearanceSettings?> load() async => null;
  @override
  Future<void> save(AppearanceSettings settings) =>
      Future.error(const FileSystemException('read-only'));
}

void main() {
  group('inNihonSeason', () {
    test('opens at the start of Oct 16 and closes after Nov 6', () {
      expect(inNihonSeason(DateTime(2026, 10, 15, 23, 59)), isFalse);
      expect(inNihonSeason(DateTime(2026, 10, 16)), isTrue);
      expect(inNihonSeason(DateTime(2026, 11, 6, 23, 59)), isTrue);
      expect(inNihonSeason(DateTime(2026, 11, 7)), isFalse);
    });

    test('comes back every year', () {
      expect(inNihonSeason(DateTime(2031, 10, 30)), isTrue);
      expect(inNihonSeason(DateTime(2031, 3, 1)), isFalse);
    });
  });

  group('AppearanceController', () {
    AppearanceController make({
      required DateTime now,
      AppearanceSettings settings = const AppearanceSettings(),
      AppearanceStore? store,
    }) {
      final c = AppearanceController(
        store: store ?? MemoryAppearanceStore(),
        settings: settings,
        clock: () => now,
      );
      addTearDown(c.dispose);
      return c;
    }

    final inSeason = DateTime(2026, 10, 20);
    final offSeason = DateTime(2026, 12, 1);

    test('defaults to Loaf Dark with easter eggs on', () {
      final c = make(now: offSeason);
      expect(c.chosen, LoafThemeId.loafDark);
      expect(c.easterEggs, isTrue);
      expect(c.effective, LoafThemeId.loafDark);
      expect(c.seasonOverrides, isFalse);
    });

    test('the season wins over the pick while easter eggs are on', () {
      final c = make(now: inSeason);
      expect(c.effective, LoafThemeId.nihon);
      expect(c.seasonOverrides, isTrue);
    });

    test('with easter eggs off, the pick applies in season', () {
      final c = make(
        now: inSeason,
        settings: const AppearanceSettings(easterEggs: false),
      );
      expect(c.effective, LoafThemeId.loafDark);
      expect(c.seasonOverrides, isFalse);
    });

    test('picking 日本 in season is not an override', () {
      final c = make(now: inSeason);
      c.choose(LoafThemeId.nihon);
      expect(c.seasonOverrides, isFalse);
    });

    test('changes notify and save', () async {
      final store = MemoryAppearanceStore();
      final c = make(now: offSeason, store: store);
      var heard = 0;
      c.addListener(() => heard++);

      c.choose(LoafThemeId.nihon);
      c.setEasterEggs(false);
      await Future<void>.delayed(Duration.zero);

      expect(heard, 2);
      expect(c.effective, LoafThemeId.nihon);
      expect(store.saved?.theme, LoafThemeId.nihon);
      expect(store.saved?.easterEggs, isFalse);
    });

    test('choosing what is already chosen changes nothing', () {
      final c = make(now: offSeason);
      var heard = 0;
      c.addListener(() => heard++);
      c.choose(LoafThemeId.loafDark);
      c.setEasterEggs(true);
      expect(heard, 0);
    });

    test('a store that cannot save still applies the pick', () async {
      final c = make(now: offSeason, store: _BrokenStore());
      c.choose(LoafThemeId.nihon);
      await Future<void>.delayed(Duration.zero);
      expect(c.effective, LoafThemeId.nihon);
    });

    test('load restores what was saved', () async {
      final c = await AppearanceController.load(
        MemoryAppearanceStore(
          const AppearanceSettings(theme: LoafThemeId.nihon, easterEggs: false),
        ),
        clock: () => offSeason,
      );
      addTearDown(c.dispose);
      expect(c.chosen, LoafThemeId.nihon);
      expect(c.easterEggs, isFalse);
    });
  });

  testWidgets('an app left open crosses into the season at midnight', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 15, 23);
    final c = AppearanceController(
      store: MemoryAppearanceStore(),
      clock: () => now,
    );
    var heard = 0;
    c.addListener(() => heard++);
    expect(c.effective, LoafThemeId.loafDark);

    now = DateTime(2026, 10, 16, 0, 0, 1);
    await tester.pump(const Duration(hours: 1));

    expect(heard, 1);
    expect(c.effective, LoafThemeId.nihon);
    c.dispose();
  });

  group('FileAppearanceStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('appearance'));
    tearDown(() => dir.deleteSync(recursive: true));

    File file() => File('${dir.path}/appearance.json');

    test('round-trips', () async {
      final store = FileAppearanceStore(file());
      await store.save(
        const AppearanceSettings(theme: LoafThemeId.nihon, easterEggs: false),
      );
      final back = await FileAppearanceStore(file()).load();
      expect(back?.theme, LoafThemeId.nihon);
      expect(back?.easterEggs, isFalse);
    });

    test('a missing file loads as nothing', () async {
      expect(await FileAppearanceStore(file()).load(), isNull);
    });

    test('a garbage file loads as nothing', () async {
      file().writeAsStringSync('{not json');
      expect(await FileAppearanceStore(file()).load(), isNull);
    });

    test('unknown or mistyped fields fall back to the defaults', () async {
      file().writeAsStringSync('{"theme": "vaporwave", "easterEggs": "yes"}');
      final back = await FileAppearanceStore(file()).load();
      expect(back?.theme, LoafThemeId.loafDark);
      expect(back?.easterEggs, isTrue);
    });
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- flutter test test/appearance_test.dart`
Expected: FAIL — `appearance.dart` does not exist.

- [ ] **Step 3: Implement** — `lib/ui/theme/appearance.dart`:

```dart
/// Which theme loaf chat wears: the one picked in settings, unless a season
/// is on and easter eggs are allowed to dress the app up anyway.
///
/// The pick and the flag are saved to a small JSON file beside the account's
/// database, and restored before the first frame so the app never flashes
/// the wrong palette.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

enum LoafThemeId {
  loafDark('Loaf Dark'),
  nihon('日本');

  const LoafThemeId(this.label);

  final String label;
}

/// Oct 16 through Nov 6, every year, by the device's own calendar: the trip
/// the 日本 theme was made for.
bool inNihonSeason(DateTime local) {
  final monthDay = local.month * 100 + local.day;
  return monthDay >= 1016 && monthDay <= 1106;
}

@immutable
class AppearanceSettings {
  const AppearanceSettings({
    this.theme = LoafThemeId.loafDark,
    this.easterEggs = true,
  });

  /// Anything unreadable falls back to that field's default, so a
  /// hand-edited file degrades instead of failing.
  factory AppearanceSettings.fromJson(Object? json) {
    if (json is! Map) return const AppearanceSettings();
    final eggs = json['easterEggs'];
    return AppearanceSettings(
      theme:
          LoafThemeId.values.where((t) => t.name == json['theme']).firstOrNull ??
          LoafThemeId.loafDark,
      easterEggs: eggs is bool ? eggs : true,
    );
  }

  final LoafThemeId theme;
  final bool easterEggs;

  Map<String, Object> toJson() => {
    'theme': theme.name,
    'easterEggs': easterEggs,
  };
}

abstract interface class AppearanceStore {
  /// Null when nothing has been saved, or what was saved can't be read.
  Future<AppearanceSettings?> load();

  Future<void> save(AppearanceSettings settings);
}

/// Forgets on exit: for tests and the mock backend.
class MemoryAppearanceStore implements AppearanceStore {
  MemoryAppearanceStore([this.saved]);

  AppearanceSettings? saved;

  @override
  Future<AppearanceSettings?> load() async => saved;

  @override
  Future<void> save(AppearanceSettings settings) async => saved = settings;
}

class FileAppearanceStore implements AppearanceStore {
  FileAppearanceStore(this.file);

  static Future<FileAppearanceStore> inSupportDirectory() async =>
      FileAppearanceStore(
        File(
          '${(await getApplicationSupportDirectory()).path}'
          '${Platform.pathSeparator}appearance.json',
        ),
      );

  final File file;

  @override
  Future<AppearanceSettings?> load() async {
    try {
      return AppearanceSettings.fromJson(jsonDecode(await file.readAsString()));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(AppearanceSettings settings) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()));
  }
}

class AppearanceController extends ChangeNotifier {
  AppearanceController({
    required AppearanceStore store,
    AppearanceSettings settings = const AppearanceSettings(),
    DateTime Function() clock = DateTime.now,
  }) : _store = store,
       _settings = settings,
       _clock = clock {
    _armMidnight();
  }

  static Future<AppearanceController> load(
    AppearanceStore store, {
    DateTime Function() clock = DateTime.now,
  }) async => AppearanceController(
    store: store,
    settings: await store.load() ?? const AppearanceSettings(),
    clock: clock,
  );

  final AppearanceStore _store;
  final DateTime Function() _clock;
  AppearanceSettings _settings;
  Timer? _midnight;

  LoafThemeId get chosen => _settings.theme;
  bool get easterEggs => _settings.easterEggs;

  LoafThemeId get effective => easterEggs && inNihonSeason(_clock())
      ? LoafThemeId.nihon
      : chosen;

  /// The season is changing what the pick alone would show — settings says
  /// so, or the picker would look broken.
  bool get seasonOverrides => effective != chosen;

  void choose(LoafThemeId theme) =>
      _update(AppearanceSettings(theme: theme, easterEggs: easterEggs));

  void setEasterEggs(bool on) =>
      _update(AppearanceSettings(theme: chosen, easterEggs: on));

  void _update(AppearanceSettings next) {
    if (next.theme == chosen && next.easterEggs == easterEggs) return;
    _settings = next;
    notifyListeners();
    // A pick that can't be saved still applies for this run; losing it at
    // the next launch beats crashing over a theme.
    _store.save(next).then((_) {}, onError: (Object _) {});
  }

  /// The season starts and ends at midnight, so an app left open re-checks
  /// then rather than waiting for a restart.
  void _armMidnight() {
    final now = _clock();
    final next = DateTime(now.year, now.month, now.day + 1);
    _midnight = Timer(next.difference(now), () {
      notifyListeners();
      _armMidnight();
    });
  }

  @override
  void dispose() {
    _midnight?.cancel();
    super.dispose();
  }
}

/// Sits above `MaterialApp`, so routes on the root navigator — the settings
/// dialog among them — can reach the controller.
class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppearanceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}
```

- [ ] **Step 4: Run to verify pass**

Run: `mise exec -- flutter test test/appearance_test.dart`
Expected: all PASS.

- [ ] **Step 5: Format and analyze** — `mise exec -- dart format lib/ui/theme/appearance.dart test/appearance_test.dart; mise exec -- flutter analyze lib/ui/theme/appearance.dart test/appearance_test.dart`. Do not commit.

---

### Task 2: 日本 palette and app wiring

**Files:**
- Modify: `lib/ui/theme/loaf_theme.dart`
- Modify: `lib/main.dart`
- Test: `test/loaf_theme_test.dart`

**Interfaces:**
- Consumes: `LoafThemeId`, `AppearanceController`, `AppearanceScope`, `MemoryAppearanceStore`, `FileAppearanceStore.inSupportDirectory()` from Task 1.
- Produces: `enum LoafDecor { none, sakura }`; `LoafTokens.decor` (named constructor param, default `LoafDecor.none`); `ThemeData loafNihonTheme()`; `ThemeData loafTheme(LoafThemeId id)` (nihon → `loafNihonTheme()`, loafDark → `loafDarkTheme()`); top-level `late final AppearanceController appearance;` in `main.dart`.

- [ ] **Step 1: Write the failing tests** — in `test/loaf_theme_test.dart`, add `loafNihonTheme()` to the list in the existing `'every themed text style sets its weight axis'` test (`for (final theme in [loafLightTheme(), loafDarkTheme(), loafNihonTheme()])`), add the import `package:loaf_native/ui/theme/appearance.dart`, and append inside `main()`:

```dart
  test('only 日本 asks for sakura', () {
    LoafDecor decor(ThemeData t) => t.extension<LoafTokens>()!.decor;
    expect(decor(loafLightTheme()), LoafDecor.none);
    expect(decor(loafDarkTheme()), LoafDecor.none);
    expect(decor(loafNihonTheme()), LoafDecor.sakura);
  });

  test('日本 is the artifact plum, dark', () {
    final t = loafNihonTheme();
    final tokens = t.extension<LoafTokens>()!;
    expect(t.brightness, Brightness.dark);
    expect(tokens.page, const Color(0xFF1F1A1D));
    expect(tokens.accent, const Color(0xFFF29BB5));
  });

  test('loafTheme maps each id to its palette', () {
    expect(
      loafTheme(LoafThemeId.nihon).extension<LoafTokens>()!.decor,
      LoafDecor.sakura,
    );
    expect(
      loafTheme(LoafThemeId.loafDark).extension<LoafTokens>()!.page,
      loafDarkTheme().extension<LoafTokens>()!.page,
    );
  });

  test('decor switches halfway through a theme lerp', () {
    final dark = loafDarkTheme().extension<LoafTokens>()!;
    final nihon = loafNihonTheme().extension<LoafTokens>()!;
    expect(dark.lerp(nihon, 0.4).decor, LoafDecor.none);
    expect(dark.lerp(nihon, 0.6).decor, LoafDecor.sakura);
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- flutter test test/loaf_theme_test.dart`
Expected: FAIL — `loafNihonTheme`, `LoafDecor`, `loafTheme` undefined.

- [ ] **Step 3: Implement in `lib/ui/theme/loaf_theme.dart`**

3a. Add `import 'appearance.dart';` under the material import. Above the `// ── Theme extension` banner add:

```dart
/// What a theme draws besides colour. Widgets that decorate read this off
/// [LoafTokens], so they follow the theme without knowing why it is on.
enum LoafDecor { none, sakura }
```

3b. In `LoafTokens`: add `this.decor = LoafDecor.none,` as the last constructor parameter; add the field after `shadowAccent`:

```dart
  /// Extra drawing the theme asks for: petals and a train for 日本.
  final LoafDecor decor;
```

In `copyWith` add the parameter `LoafDecor? decor,` and `decor: decor ?? this.decor,`. In `lerp` add `decor: t < 0.5 ? decor : other.decor,` (an enum can't be blended; it flips halfway, like Material does for its own enums).

3c. After `_darkTokens` add:

```dart
// 日本: the dark plum of the "日本 Again" trip checklist. Pink leads where
// Loaf leads with red, and dark ink sits on it because white on pink is too
// faint to read. Surfaces darken towards the edges, as in the navy theme.
const _nihonTokens = LoafTokens(
  rail: Color(0xFF140F12),
  onRail: Color(0xFFF6E9EC),
  sidebar: Color(0xFF191417),
  page: Color(0xFF1F1A1D),
  sunken: Color(0xFF171215),
  card: Color(0xFF2A2327),
  border: Color(0xFF3D3237),
  borderStrong: Color(0xFF4D3F45),
  textStrong: Color(0xFFF6E9EC),
  textBody: Color(0xFFE6D3D8),
  textMuted: Color(0xFFBFA6AD),
  textOnAccent: Color(0xFF1F1A1D),
  accent: Color(0xFFF29BB5),
  accentHover: Color(0xFFFF6B73),
  accentSoft: Color(0xFF3A2A31),
  nameModerator: Color(0xFFFF6B73),
  online: Color(0xFFA9C88A),
  idle: _warning,
  shadowSm: [
    BoxShadow(color: Color(0x40000000), blurRadius: 3, offset: Offset(0, 1)),
  ],
  shadowMd: [
    BoxShadow(color: Color(0x4D000000), blurRadius: 12, offset: Offset(0, 4)),
  ],
  shadowLg: [
    BoxShadow(color: Color(0x59000000), blurRadius: 24, offset: Offset(0, 8)),
  ],
  shadowAccent: [
    BoxShadow(color: Color(0x59F29BB5), blurRadius: 16, offset: Offset(0, 4)),
  ],
  decor: LoafDecor.sakura,
);
```

3d. Change `_theme`'s signature to
`ThemeData _theme(LoafTokens t, Brightness brightness, {Color secondary = _primary700, Color onSecondary = _cream})` and use `secondary: secondary, onSecondary: onSecondary,` in its `ColorScheme`. At the bottom add:

```dart
// Navy has no place in the plum palette, so 日本 takes its secondary from
// its own surfaces.
ThemeData loafNihonTheme() => _theme(
  _nihonTokens,
  Brightness.dark,
  secondary: _nihonTokens.card,
  onSecondary: _nihonTokens.textStrong,
);

/// The theme settings means by [id].
ThemeData loafTheme(LoafThemeId id) => switch (id) {
  LoafThemeId.loafDark => loafDarkTheme(),
  LoafThemeId.nihon => loafNihonTheme(),
};
```

- [ ] **Step 4: Run to verify pass**

Run: `mise exec -- flutter test test/loaf_theme_test.dart`
Expected: all PASS.

- [ ] **Step 5: Wire it into `lib/main.dart`**

Add imports `ui/theme/appearance.dart`. Below `themeMode` add:

```dart
/// Which theme the app wears. Lives as long as the app, like [themeMode].
late final AppearanceController appearance;
```

At the top of `main()`, right after `WidgetsFlutterBinding.ensureInitialized();`:

```dart
  // Restored before the first frame, like the session, so the app never
  // flashes the wrong palette. The mock keeps nothing between runs.
  appearance = await AppearanceController.load(
    backend == 'mock'
        ? MemoryAppearanceStore()
        : await FileAppearanceStore.inSupportDirectory(),
  );
```

In `LoafApp.build`, replace the outer `ValueListenableBuilder(valueListenable: themeMode, builder: (context, mode, _) => MaterialApp(` with:

```dart
  Widget build(BuildContext context) => AppearanceScope(
    controller: appearance,
    child: ListenableBuilder(
      listenable: Listenable.merge([appearance, themeMode]),
      builder: (context, _) {
        final mode = themeMode.value;
        // 日本 has one palette, so it fills both slots and Ctrl+T leaves it be.
        final nihon = appearance.effective == LoafThemeId.nihon;
        return MaterialApp(
          title: 'Loaf Chat',
          debugShowCheckedModeBanner: false,
          theme: nihon ? loafNihonTheme() : loafLightTheme(),
          darkTheme: nihon ? loafNihonTheme() : loafDarkTheme(),
          themeMode: mode,
          home: /* the existing CallbackShortcuts subtree, unchanged */,
        );
      },
    ),
  );
```

Keep the existing `home:` `CallbackShortcuts(...)` subtree exactly as it is (its Ctrl+T handler still reads `mode`). Close the brackets accordingly.

- [ ] **Step 6: Full suite** — `mise exec -- flutter test` — expected: everything passes (other tests build their own `MaterialApp` and are unaffected). Then `mise exec -- dart format lib test; mise exec -- flutter analyze`. Do not commit.

---

### Task 3: Sakura decor — petals and the Shinkansen

**Files:**
- Create: `lib/ui/theme/sakura.dart`
- Modify: `lib/ui/channel/channel_view.dart` (the timeline `Expanded` and the composer `ListenableBuilder`, around lines 130–170)
- Test: `test/sakura_test.dart`

**Interfaces:**
- Consumes: `LoafDecor`, `LoafTokens.decor`, `loafNihonTheme()`, `loafDarkTheme()` from Task 2.
- Produces: `class SakuraPetals extends StatelessWidget` (`const SakuraPetals()`) and `class ShinkansenRail extends StatelessWidget` (`const ShinkansenRail()`, `static const height = 46.0`).

- [ ] **Step 1: Write the failing tests** — `test/sakura_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/theme/sakura.dart';

Future<void> _pump(
  WidgetTester tester,
  ThemeData theme, {
  bool reduceMotion = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: theme,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: reduceMotion),
        child: const Scaffold(
          body: Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [SakuraPetals()],
                ),
              ),
              ShinkansenRail(),
            ],
          ),
        ),
      ),
    ),
  ),
);

Finder _paintIn(Type type) =>
    find.descendant(of: find.byType(type), matching: find.byType(CustomPaint));

void main() {
  testWidgets('Loaf Dark draws nothing and takes no room', (tester) async {
    await _pump(tester, loafDarkTheme());
    expect(_paintIn(SakuraPetals), findsNothing);
    expect(_paintIn(ShinkansenRail), findsNothing);
    expect(tester.getSize(find.byType(ShinkansenRail)).height, 0);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('日本 draws petals and a moving train', (tester) async {
    await _pump(tester, loafNihonTheme());
    expect(_paintIn(SakuraPetals), findsOneWidget);
    expect(_paintIn(ShinkansenRail), findsOneWidget);
    expect(
      tester.getSize(find.byType(ShinkansenRail)).height,
      ShinkansenRail.height,
    );
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion: no petals, a still train, nothing ticking', (
    tester,
  ) async {
    await _pump(tester, loafNihonTheme(), reduceMotion: true);
    expect(_paintIn(SakuraPetals), findsNothing);
    expect(_paintIn(ShinkansenRail), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('decor never takes a tap', (tester) async {
    await _pump(tester, loafNihonTheme());
    expect(
      find.descendant(
        of: find.byType(ShinkansenRail),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byType(SakuraPetals),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- flutter test test/sakura_test.dart`
Expected: FAIL — `sakura.dart` does not exist.

- [ ] **Step 3: Implement** — `lib/ui/theme/sakura.dart`:

```dart
/// The 日本 theme's decor: sakura petals drifting behind the conversation and
/// a little Shinkansen crossing above the composer, both lifted from the
/// "日本 Again" trip checklist.
///
/// Each draws nothing unless the theme asks for sakura, never takes a tap or
/// a screen reader's attention, and holds still when the system asks for
/// less motion.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'loaf_theme.dart';

bool _wantsSakura(BuildContext context) =>
    LoafTokens.of(context).decor == LoafDecor.sakura;

/// Fills its parent; put it behind the content in a `Stack`.
class SakuraPetals extends StatelessWidget {
  const SakuraPetals({super.key});

  @override
  Widget build(BuildContext context) {
    if (!_wantsSakura(context) || MediaQuery.disableAnimationsOf(context)) {
      return const SizedBox.shrink();
    }
    return const IgnorePointer(child: ExcludeSemantics(child: _Petals()));
  }
}

class _Petals extends StatefulWidget {
  const _Petals();

  @override
  State<_Petals> createState() => _PetalsState();
}

class _PetalsState extends State<_Petals> with SingleTickerProviderStateMixin {
  final _elapsed = ValueNotifier(Duration.zero);
  late final Ticker _ticker;
  // Seeded, so the same petals fall every time and tests see one picture.
  final _petals = List.generate(18, (_) => _Petal(_random), growable: false);
  static final _random = math.Random(1016);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) => _elapsed.value = elapsed)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: CustomPaint(
      painter: _PetalPainter(_petals, _elapsed, LoafTokens.of(context).accent),
    ),
  );
}

/// Where a petal starts and how it moves. Its position is a pure function of
/// time, so the painter needs no per-frame state.
class _Petal {
  _Petal(math.Random r)
    : x = r.nextDouble(),
      y = r.nextDouble(),
      size = 6 + r.nextDouble() * 7,
      fall = 0.04 + r.nextDouble() * 0.06,
      spin = r.nextDouble() * 6,
      sway = r.nextDouble() * 6;

  final double x, y, size, fall, spin, sway;
}

class _PetalPainter extends CustomPainter {
  _PetalPainter(this.petals, this.elapsed, this.color)
    : super(repaint: elapsed);

  final List<_Petal> petals;
  final ValueNotifier<Duration> elapsed;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final t = elapsed.value.inMicroseconds / Duration.microsecondsPerSecond;
    final paint = Paint()..color = color.withValues(alpha: 0.55);
    for (final p in petals) {
      // Wraps from just below the bottom edge to just above the top one.
      final y = (p.y + p.fall * t) % 1.1 - 0.05;
      final x = p.x + 0.02 * math.sin(t / 1.6 + p.sway);
      final s = p.size;
      canvas
        ..save()
        ..translate(x * size.width, y * size.height)
        ..rotate(p.spin + 0.6 * t)
        ..drawPath(
          Path()
            ..moveTo(0, -s)
            ..cubicTo(s * .9, -s * .6, s * .7, s * .6, 0, s)
            ..cubicTo(-s * .7, s * .6, -s * .9, -s * .6, 0, -s),
          paint,
        )
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_PetalPainter old) =>
      old.color != color || old.petals != petals;
}

/// A strip of track above the composer with the train running along it.
class ShinkansenRail extends StatelessWidget {
  const ShinkansenRail({super.key});

  static const height = 46.0;

  @override
  Widget build(BuildContext context) {
    if (!_wantsSakura(context)) return const SizedBox.shrink();
    return IgnorePointer(
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: _Rail(moving: !MediaQuery.disableAnimationsOf(context)),
        ),
      ),
    );
  }
}

class _Rail extends StatefulWidget {
  const _Rail({required this.moving});

  final bool moving;

  @override
  State<_Rail> createState() => _RailState();
}

class _RailState extends State<_Rail> with SingleTickerProviderStateMixin {
  final _elapsed = ValueNotifier(Duration.zero);
  late final Ticker _ticker = createTicker((e) => _elapsed.value = e);

  @override
  void initState() {
    super.initState();
    if (widget.moving) _ticker.start();
  }

  @override
  void didUpdateWidget(_Rail old) {
    super.didUpdateWidget(old);
    if (widget.moving && !_ticker.isActive) _ticker.start();
    if (!widget.moving && _ticker.isActive) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: CustomPaint(
      painter: _RailPainter(
        elapsed: _elapsed,
        moving: widget.moving,
        tokens: LoafTokens.of(context),
      ),
    ),
  );
}

class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.elapsed,
    required this.moving,
    required this.tokens,
  }) : super(repaint: elapsed);

  final ValueNotifier<Duration> elapsed;
  final bool moving;
  final LoafTokens tokens;

  /// The train's own drawing space: the checklist's SVG viewBox.
  static const _trainWidth = 300.0;
  static const _trainHeight = 34.0;
  static const _crossing = 14.0; // seconds per pass

  @override
  void paint(Canvas canvas, Size size) {
    _paintTrack(canvas, size);

    final t = elapsed.value.inMicroseconds / Duration.microsecondsPerSecond;
    final double left;
    final double bob;
    if (moving) {
      final progress = (t % _crossing) / _crossing;
      left = -_trainWidth - 20 + progress * (size.width + _trainWidth + 40);
      // Up a pixel and back once a second, like a carriage on the joints.
      bob = -(1 - math.cos(2 * math.pi * t)) / 2;
    } else {
      left = size.width - _trainWidth - 16;
      bob = 0;
    }
    canvas
      ..save()
      ..translate(left, size.height - 9 - _trainHeight + bob);
    _paintTrain(canvas);
    canvas.restore();
  }

  void _paintTrack(Canvas canvas, Size size) {
    final paint = Paint()..color = tokens.textMuted.withValues(alpha: 0.45);
    final top = size.height - 6 - 3;
    for (var x = 0.0; x < size.width; x += 22) {
      canvas.drawRect(Rect.fromLTWH(x, top, 14, 3), paint);
    }
  }

  void _paintTrain(Canvas canvas) {
    final body = Paint()..color = tokens.card;
    final outline = Paint()
      ..color = tokens.textStrong
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final stripe = Paint()..color = tokens.accent;
    final glass = Paint()..color = tokens.textStrong.withValues(alpha: 0.8);
    final wheel = Paint()..color = tokens.textStrong;

    final cars = [
      // Rear car.
      Path()
        ..moveTo(4, 8)
        ..quadraticBezierTo(4, 4, 8, 4)
        ..lineTo(92, 4)
        ..lineTo(92, 28)
        ..lineTo(8, 28)
        ..quadraticBezierTo(4, 28, 4, 24)
        ..close(),
      // Middle car.
      Path()..addRect(const Rect.fromLTRB(96, 4, 184, 28)),
      // Lead car, with the long nose.
      Path()
        ..moveTo(188, 4)
        ..lineTo(236, 4)
        ..cubicTo(262, 4, 284, 14, 296, 26)
        ..quadraticBezierTo(297, 28, 294, 28)
        ..lineTo(188, 28)
        ..close(),
    ];
    for (final car in cars) {
      canvas
        ..drawPath(car, body)
        ..drawPath(car, outline);
    }

    canvas
      ..drawRect(const Rect.fromLTWH(4, 19, 88, 3), stripe)
      ..drawRect(const Rect.fromLTWH(96, 19, 88, 3), stripe)
      ..drawPath(
        Path()
          ..moveTo(188, 19)
          ..lineTo(274, 19)
          ..quadraticBezierTo(279, 20.5, 282, 22)
          ..lineTo(188, 22)
          ..close(),
        stripe,
      );

    for (final x in const [12.0, 28, 44, 60, 76, 104, 120, 136, 152, 168, 196, 212]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 9, 10, 6),
          const Radius.circular(2),
        ),
        glass,
      );
    }
    // The driver's windscreen.
    canvas.drawPath(
      Path()
        ..moveTo(244, 7)
        ..cubicTo(256, 8, 266, 12, 272, 16)
        ..lineTo(246, 16)
        ..quadraticBezierTo(243, 16, 243, 13)
        ..close(),
      glass,
    );

    for (final x in const [20.0, 76, 112, 168, 204, 262]) {
      canvas.drawCircle(Offset(x, 30), 2.5, wheel);
    }
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.moving != moving || old.tokens != tokens;
}
```

- [ ] **Step 4: Run to verify pass**

Run: `mise exec -- flutter test test/sakura_test.dart`
Expected: all PASS.

- [ ] **Step 5: Place the decor in `lib/ui/channel/channel_view.dart`**

Import `../theme/sakura.dart`. Replace the timeline `Expanded` (the one whose child is `_Timeline(key: ObjectKey(timeline), …)`) with:

```dart
              Expanded(
                // Petals drift over the page colour, behind the messages;
                // the timeline paints no background of its own.
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const SakuraPetals(),
                    // Keyed by the conversation, so switching rooms starts a
                    // fresh list that listens to the room it shows.
                    _Timeline(
                      key: ObjectKey(timeline),
                      controller: timeline!,
                      onRead: onRead,
                    ),
                  ],
                ),
              ),
```

In the composer `ListenableBuilder`, wrap the writable branch so the rail sits directly above the composer and only when it shows:

```dart
                builder: (context, _) => timeline!.writable
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const ShinkansenRail(),
                          Composer(
                            // (existing key, comment and arguments unchanged)
                          ),
                        ],
                      )
                    : _EncryptedNote(trust: trust, onVerify: onVerify),
```

Keep the `Composer`'s existing key, comment and arguments verbatim.

- [ ] **Step 6: Full suite** — `mise exec -- flutter test` — expected: all pass (existing channel-view tests use `loafDarkTheme()`, where both widgets are `SizedBox.shrink()`). Then `mise exec -- dart format lib test; mise exec -- flutter analyze`. Do not commit.

---

### Task 4: Appearance section in settings

**Files:**
- Create: `lib/ui/settings/appearance_section.dart`
- Modify: `lib/ui/settings/settings_page.dart` (enum `SettingsSection`, `_SettingsModalState._sections`, `_Detail.build`)
- Modify: `test/settings_test.dart` (the `'lists only sections that do something'` test)
- Test: `test/appearance_section_test.dart`

**Interfaces:**
- Consumes: `AppearanceController`, `AppearanceScope.maybeOf`, `LoafThemeId`, `MemoryAppearanceStore`, `AppearanceSettings` (Task 1); `loafTheme(LoafThemeId)`, `LoafTokens` (Task 2).
- Produces: `class AppearanceSection extends StatelessWidget` (`const AppearanceSection({required AppearanceController controller})`); `SettingsSection.appearance`.

- [ ] **Step 1: Write the failing tests** — `test/appearance_section_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/settings/appearance_section.dart';
import 'package:loaf_native/ui/theme/appearance.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';

Future<AppearanceController> _pump(
  WidgetTester tester, {
  required DateTime now,
  AppearanceSettings settings = const AppearanceSettings(),
}) async {
  final c = AppearanceController(
    store: MemoryAppearanceStore(),
    settings: settings,
    clock: () => now,
  );
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      home: Scaffold(body: AppearanceSection(controller: c)),
    ),
  );
  return c;
}

final _inSeason = DateTime(2026, 10, 20);
final _offSeason = DateTime(2026, 12, 1);

void main() {
  testWidgets('offers both themes by name', (tester) async {
    await _pump(tester, now: _offSeason);
    expect(find.text('Loaf Dark'), findsOneWidget);
    expect(find.text('日本'), findsOneWidget);
  });

  testWidgets('tapping a theme picks it', (tester) async {
    final c = await _pump(tester, now: _offSeason);
    await tester.tap(find.text('日本'));
    await tester.pump();
    expect(c.chosen, LoafThemeId.nihon);
  });

  testWidgets('the easter eggs box drives the flag', (tester) async {
    final c = await _pump(tester, now: _offSeason);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    await tester.tap(find.text('easter eggs'));
    await tester.pump();
    expect(c.easterEggs, isFalse);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
  });

  testWidgets('says so while the season overrides the pick', (tester) async {
    final c = await _pump(tester, now: _inSeason);
    expect(find.textContaining('until Nov 6'), findsOneWidget);

    c.setEasterEggs(false);
    await tester.pump();
    expect(find.textContaining('until Nov 6'), findsNothing);
  });

  testWidgets('no override note out of season', (tester) async {
    await _pump(tester, now: _offSeason);
    expect(find.textContaining('until Nov 6'), findsNothing);
  });
}
```

In `test/settings_test.dart`:
- Add imports `package:loaf_native/ui/theme/appearance.dart`.
- Give `_open` an optional `AppearanceController? appearance` parameter and, when non-null, wrap the `MaterialApp` in `AppearanceScope(controller: appearance, child: MaterialApp(...))`.
- In `'lists only sections that do something'`, remove `'appearance'` from the gone-list.
- Add:

```dart
  testWidgets('appearance is listed only with a controller behind it', (
    tester,
  ) async {
    await _open(tester, const Size(1440, 900));
    expect(find.text('appearance'), findsNothing);
  });

  testWidgets('appearance opens the theme picker', (tester) async {
    final appearance = AppearanceController(store: MemoryAppearanceStore());
    addTearDown(appearance.dispose);
    await _open(tester, const Size(1440, 900), appearance: appearance);

    await tester.tap(find.text('appearance'));
    await tester.pumpAndSettle();
    expect(find.text('Loaf Dark'), findsOneWidget);
    expect(find.text('日本'), findsOneWidget);
  });
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- flutter test test/appearance_section_test.dart test/settings_test.dart`
Expected: FAIL — `appearance_section.dart` missing / no `appearance` entry.

- [ ] **Step 3: Implement** — `lib/ui/settings/appearance_section.dart`:

```dart
/// Appearance — which theme loaf chat wears, and whether the seasons may
/// dress it up anyway.
///
/// While a season is overriding the pick, the section says so: otherwise
/// tapping a theme and seeing nothing change would look broken.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/appearance.dart';
import '../theme/loaf_theme.dart';

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key, required this.controller});

  final AppearanceController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final tokens = LoafTokens.of(context);
      final muted = loafBody(13, 400).copyWith(color: tokens.textMuted);
      return ListView(
        padding: const EdgeInsets.all(LoafSpace.x6),
        children: [
          _Label(tokens: tokens, label: 'theme'),
          for (final id in LoafThemeId.values) ...[
            _ThemeRow(
              id: id,
              selected: controller.chosen == id,
              onTap: () => controller.choose(id),
            ),
            const SizedBox(height: LoafSpace.x2),
          ],
          if (controller.seasonOverrides) ...[
            const SizedBox(height: LoafSpace.x1),
            Text(
              '${LoafThemeId.nihon.label} is on for the season, until Nov 6. '
              'turn off easter eggs to use your pick.',
              style: muted,
            ),
          ],
          const SizedBox(height: LoafSpace.x6),
          _EasterEggs(
            value: controller.easterEggs,
            onChanged: controller.setEasterEggs,
          ),
        ],
      );
    },
  );
}

class _Label extends StatelessWidget {
  const _Label({required this.tokens, required this.label});

  final LoafTokens tokens;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: LoafSpace.x2),
    child: Text(
      label.toUpperCase(),
      style: loafBody(
        11,
        600,
      ).copyWith(color: tokens.textMuted, letterSpacing: 0.04 * 11),
    ),
  );
}

class _ThemeRow extends StatelessWidget {
  const _ThemeRow({
    required this.id,
    required this.selected,
    required this.onTap,
  });

  final LoafThemeId id;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    // The swatch shows the theme's own page and accent, not the current one.
    final own = loafTheme(id).extension<LoafTokens>()!;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? tokens.card : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoafRadius.lg),
          side: BorderSide(
            color: selected ? tokens.borderStrong : tokens.border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(LoafSpace.x3),
            child: Row(
              children: [
                _Swatch(page: own.page, accent: own.accent),
                const SizedBox(width: LoafSpace.x3),
                Expanded(
                  child: Text(
                    id.label,
                    style: loafBody(15, 600).copyWith(color: tokens.textStrong),
                  ),
                ),
                if (selected)
                  Icon(LucideIcons.check, size: 18, color: tokens.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.page, required this.accent});

  final Color page;
  final Color accent;

  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 32,
    decoration: BoxDecoration(
      color: page,
      borderRadius: BorderRadius.circular(LoafRadius.md),
      border: Border.all(color: LoafTokens.of(context).border),
    ),
    alignment: Alignment.center,
    child: Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
    ),
  );
}

class _EasterEggs extends StatelessWidget {
  const _EasterEggs({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(LoafRadius.lg),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: LoafSpace.x2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: value,
                activeColor: tokens.accent,
                checkColor: tokens.textOnAccent,
                onChanged: (v) => onChanged(v ?? true),
              ),
              const SizedBox(width: LoafSpace.x2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: LoafSpace.x2),
                    Text(
                      'easter eggs',
                      style: loafBody(15, 600).copyWith(
                        color: tokens.textStrong,
                      ),
                    ),
                    Text(
                      'seasonal surprises, like ${LoafThemeId.nihon.label} '
                      'from Oct 16 to Nov 6.',
                      style: loafBody(13, 400).copyWith(
                        color: tokens.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

In `lib/ui/settings/settings_page.dart`:
- Import `../theme/appearance.dart` and `appearance_section.dart`.
- Enum: add `appearance('appearance', LucideIcons.palette),` between `account` and `devices`.
- `_sections`: make it take the context's controller —

```dart
  /// What this backend can back. The account always; appearance only with a
  /// controller to change; devices only with something that lists them.
  List<SettingsSection> get _sections => [
    SettingsSection.account,
    if (AppearanceScope.maybeOf(context) != null) SettingsSection.appearance,
    if (widget.devices != null) SettingsSection.devices,
    SettingsSection.about,
  ];
```

  Because `_section` is a `late` field initialised from `_sections`, and `context` is valid by the time `late` fields are first read in `build`, this is safe; if `_section` is read in `initState`, move that read into `didChangeDependencies` instead.
- `_Detail`: add a case

```dart
    // Only offered with a controller in scope; the null check is the
    // backstop.
    SettingsSection.appearance => switch (AppearanceScope.maybeOf(context)) {
      final controller? => AppearanceSection(controller: controller),
      null => AccountSection(profile: profile, me: me, editable: editable),
    },
```

- [ ] **Step 4: Run to verify pass**

Run: `mise exec -- flutter test test/appearance_section_test.dart test/settings_test.dart`
Expected: all PASS.

- [ ] **Step 5: Full suite** — `mise exec -- flutter test`, then `mise exec -- dart format lib test; mise exec -- flutter analyze`. Do not commit.
