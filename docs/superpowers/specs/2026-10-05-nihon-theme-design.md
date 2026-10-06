# 日本 theme — design

A seasonal easter egg: a sakura theme lifted from the "日本 Again" trip
checklist artifact, with drifting petals and a little Shinkansen. It turns on
for everyone from Oct 16 to Nov 6, and settings gains an appearance section
to pick a theme by hand.

## Decisions

- **Two themes.** `Loaf Dark` (today's navy palette) and `日本` (the
  artifact's dark plum palette). The light palette stays a design-time
  Ctrl+T flip and is not offered in settings.
- **The window wins.** From Oct 16 00:00 through Nov 6 23:59, local time,
  every year, 日本 is the effective theme regardless of the pick — unless
  **easter eggs** is turned off, in which case the pick always applies.
  Easter eggs is on by default.
- **Fonts unchanged.** Outfit and Lora; no Japanese display face is bundled.
- **Same on every platform.** Desktop and phone both get the decor.

## Model — `lib/ui/theme/appearance.dart`

- `enum LoafThemeId { loafDark('Loaf Dark'), nihon('日本') }` with a `label`.
- `bool inNihonSeason(DateTime local)` — month/day between 10-16 and 11-06
  inclusive. Pure, so the edges are unit-tested.
- `abstract interface class AppearanceStore { Future<AppearanceSettings?>
  load(); Future<void> save(AppearanceSettings); }`, with
  - `FileAppearanceStore` — `appearance.json` in
    `getApplicationSupportDirectory()` (already a dependency). A missing or
    unreadable file loads as null; unknown theme names fall back to Loaf Dark.
  - `MemoryAppearanceStore` — for tests and the mock backend.
- `AppearanceSettings { LoafThemeId theme; bool easterEggs; }`, JSON
  `{"theme": "loafDark", "easterEggs": true}`.
- `class AppearanceController extends ChangeNotifier`
  - constructed with a store and a `DateTime Function() clock`
    (defaults to `DateTime.now`).
  - `chosen`, `easterEggs`, `choose(id)`, `setEasterEggs(bool)` — each
    change notifies and saves.
  - `effective` → `nihon` when `easterEggs && inNihonSeason(clock())`, else
    `chosen`. `seasonOverrides` → true when the window is changing the
    result (`effective != chosen`).
  - A one-shot `Timer` to the next local midnight re-notifies (and re-arms),
    so an app left open crosses the window's edges on its own. Cancelled in
    `dispose`.
  - `static Future<AppearanceController> load(store, {clock})` restores
    before the first frame, like the session does.
- `class AppearanceScope extends InheritedNotifier<AppearanceController>`
  with `maybeOf(context)`. It wraps `MaterialApp`, so the settings dialog
  (a root-navigator route) can see it.

## Palette — `lib/ui/theme/loaf_theme.dart`

`LoafTokens` gains `final LoafDecor decor;` (`enum LoafDecor { none, sakura
}`), copied in `copyWith` and switched at `t < 0.5` in `lerp`. Light and
Loaf Dark tokens carry `none`.

`_nihonTokens` (dark plum, from the artifact):

| token | value | note |
|---|---|---|
| rail | `#140f12` | darkest plum step |
| onRail | `#f6e9ec` | |
| sidebar | `#191417` | |
| page | `#1f1a1d` | artifact `--paper` |
| sunken | `#171215` | |
| card | `#2a2327` | `--card` |
| border | `#3d3237` | `--line` |
| borderStrong | `#4d3f45` | |
| textStrong | `#f6e9ec` | `--ink` |
| textBody | `#e6d3d8` | |
| textMuted | `#bfa6ad` | `--muted` |
| textOnAccent | `#1f1a1d` | dark ink on pink reads; white does not |
| accent | `#f29bb5` | `--sakura-deep` |
| accentHover | `#ff6b73` | `--hanko` |
| accentSoft | `#3a2a31` | `--chip` |
| nameModerator | `#ff6b73` | |
| online | `#a9c88a` | `--matcha` |
| idle | `#d97b2a` | shared warning |
| shadows | as Loaf Dark; `shadowAccent` tinted `#f29bb5` | |
| decor | `sakura` | |

`ThemeData loafNihonTheme()` and `ThemeData loafTheme(LoafThemeId)`. The
ColorScheme's `secondary` comes from tokens rather than the navy constant
(`secondary: t.card`, `onSecondary: t.textStrong` for 日本; Loaf keeps navy) —
done by adding `secondary`/`onSecondary` params to `_theme`.

## Wiring — `lib/main.dart`

`main` loads `AppearanceController` (file store for matrix, memory store for
mock) before `runApp`. `LoafApp` wraps `MaterialApp` in `AppearanceScope` and
a `ListenableBuilder` on both the controller and `themeMode`:

- effective `nihon` → `theme: loafNihonTheme(), darkTheme: loafNihonTheme()`.
- effective `loafDark` → today's behaviour (light/dark + Ctrl+T).

## Decor — `lib/ui/theme/sakura.dart`

Both only exist when `LoafTokens.of(context).decor == LoafDecor.sakura`;
both sit in `IgnorePointer` and `ExcludeSemantics`.

- **`SakuraPetals`** — a `StatefulWidget` with a `Ticker` and a
  `CustomPainter`: 18 petals (seeded `Random`, so tests are stable), size
  6–13 logical px, fall speed 0.04–0.10 of height per second, sideways sway
  `sin(t/1.6s + phase)`, slow spin; same two-bezier petal shape as the
  artifact; `accent` at 55% opacity. Wraps around when a petal leaves the
  bottom.
- **`ShinkansenRail`** — a 46px-high strip: dashed rail (`textMuted` at 45%,
  14px dash / 8px gap) 6px from its bottom; the train, painted from the
  artifact's SVG geometry (300×34 viewBox: three cars, long nose, `card`
  body with `textStrong` stroke, `accent` stripe, `textStrong` 80% windows
  and wheels), scaled to 34px tall. It crosses from `-train width` to `width
  + 20` every 14 s, linear, with a 1px bob every 0.5 s.
- **Reduced motion** (`MediaQuery.disableAnimationsOf`): no petals; the train
  is drawn still, right-aligned 16px from the end.
- **Placement** — `channel_view.dart`: the timeline's `Expanded` becomes a
  `Stack` of `SakuraPetals` (behind) and the timeline; `ShinkansenRail` sits
  in the `Column` directly above the composer (only when the composer
  shows). Under Loaf Dark both widgets build `SizedBox.shrink()`, so the
  layout is unchanged.

## Settings — `lib/ui/settings/appearance_section.dart`

- `SettingsSection.appearance('appearance', LucideIcons.palette)`, listed
  after account, only when `AppearanceScope.maybeOf(context)` is non-null
  (no controller → nothing behind it → not listed, per the settings rule).
- **Theme** — two selectable rows, styled like the rest of settings: a
  swatch (page + accent of that theme), the label, and a check on the
  `chosen` one. Tapping calls `choose`.
- **Override note** — while `seasonOverrides`: "日本 is on until Nov 6 for
  the season. Turn off easter eggs to use your pick."
- **Easter eggs** — a checkbox row: "Easter eggs" / "Seasonal surprises,
  like 日本 from Oct 16 to Nov 6."
- The existing "lists only sections that do something" test drops
  `appearance` from its gone-list; it is present with a scope and absent
  without one.

## Testing

- `test/appearance_test.dart` — `inNihonSeason` at Oct 15 23:59 (false),
  Oct 16 00:00 (true), Nov 6 23:59 (true), Nov 7 00:00 (false), another year
  (true); `effective` with easter eggs on/off in and out of season;
  `choose`/`setEasterEggs` notify and save; file store round-trip, missing
  file, garbage file, unknown theme.
- `test/sakura_test.dart` — decor absent under Loaf Dark; present under
  日本; with `disableAnimations` there are no petals and the train is
  static (pumping time moves nothing, no pending ticker).
- `test/appearance_section_test.dart` — rows and checkbox drive the
  controller; override note shows only in season with easter eggs on.
- `test/loaf_theme_test.dart` — the font-axis check covers the 日本 theme.
