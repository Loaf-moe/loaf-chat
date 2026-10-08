# Window Chrome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the OS title bar and window buttons on macOS, Linux and Windows with Loaf-themed controls folded into the app's own columns, keeping each OS's real window behaviour, and with no controls on Linux tiling window managers.

**Architecture:** Each runner hides its frame and answers one method channel, `loaf/window` (minimize / maximize / close / drag / double-click, plus state events). On the Dart side, a pure `window_state.dart` turns what the runner reports into a `WindowState` that says which buttons go on which side. It is unit-tested. `window_chrome.dart` holds the controller, an `InheritedNotifier` installed in `MaterialApp.builder`, and four widgets the surfaces use:
- `WindowEdges`: which top corners a column touches
- `WindowDragArea`: makes a bar move the window
- `WindowControls`: the buttons for one corner
- `WindowBand`: a 56pt draggable top band for surfaces with no bar

**Tech Stack:**
- Dart: Flutter 3.47.5 (pinned in `mise.toml`; run every command through `mise exec --`) and `lucide_icons_flutter`.
- macOS: Swift / AppKit.
- Linux: GTK3 C++ (`flutter_linux`).
- Windows: Win32 C++ (`flutter` client wrapper, DWM, comctl32).

**Spec:** `docs/superpowers/specs/2026-10-06-window-chrome-design.md`. Read it first. Where this plan differs from the spec, Task 3 Step 7 writes the difference back into the spec. The differences are:
- **Bands are 56pt.** They match the headers, so controls line up across columns.
- **No root-level overlay.** Each bar holds its own controls, chosen by `WindowEdges`.
- **Linux keeps CSD on tiling WMs** instead of going undecorated. GTK already drops shadows and resize margins on tiled windows, and floating windows keep their resize edges.
- **Linux `startDrag` uses the pointer's current position** instead of a recorded press event. The press is still held when Flutter's pan starts, so the WM sees a live button, and nothing depends on FlView's internal event handling.
- **Windows adds `maxHovered`** to the state. Over the maximize button, mouse events go to the frame and not to Flutter, so the runner has to tell Dart when to show hover.
- **Tests live flat in `test/`,** as every other UI test does.

## Global Constraints

- Every Dart command runs as `mise exec -- flutter …` from the worktree root `/Users/faore/code/loaf-native/.claude/worktrees/feat-window-chrome`.
- Mobile is untouched. Every widget here renders `SizedBox.shrink()`, or passes its child through, when there is no `WindowChrome` ancestor or the platform is not desktop. Existing tests have no `WindowChrome`, so they must keep passing unchanged.
- Channel name: exactly `loaf/window`.
  - Methods: `state`, `minimize`, `toggleMaximize`, `close`, `startDrag`, `titlebarDoubleClick`, `setMaxButtonRect`.
  - Event: `stateChanged`.
  - State map keys: `maximized`, `fullscreen`, `focused`, `maxHovered`, `wmName`, `env`, `tiled`, `decorationLayout`.
- Button keys, which tests rely on: `ValueKey('window-minimize')`, `ValueKey('window-maximize')`, `ValueKey('window-close')`.
- Band and bar height: `WindowMetrics.band = 56.0`.
- Colours come only from `LoafTokens.of(context)`:
  - close is `accent`, minimize is `idle`, zoom is `online`
  - the resting dot is `textMuted` at 55% alpha, and an unfocused dot is `border`
  - pill hover is `card`, and the close pill's hover is `accent` with a `textOnAccent` icon
- Comments say *why*, matching the surrounding code's voice. No `print`; use `debugPrint('[loaf window] …')`.
- Commit messages follow the repo's style, `feat(window): …` / `fix(window): …`, and end with:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- Never run the macOS debug build while the installed Loaf Chat is running (they share a bundle id and database). Check `pgrep -x "Loaf Chat"` first.

## Review Focus

1. A click on a button that sits inside a draggable header (members toggle, call buttons, hamburger) acts on the first click, with no double-tap delay, and never moves the window. *Task 2: "a button inside a drag area takes its tap at once".*
2. Each top corner shows its controls exactly once in every shell layout: wide with members, wide without, narrow, call fullscreen. Never zero, and never twice. *Task 3: the shell placement tests.*
3. Odd `gtk-decoration-layout` strings (whitespace, no colon, duplicates, only unknown names) parse to something sane, and never throw. *Task 1: parse tests.*
4. A runner without the channel (tests, an older build) or one throwing `PlatformException` leaves the app working with no buttons, and clicks don't throw. *Task 2: "a missing runner is quietly no buttons".*
5. On macOS, clicks in the top 28pt (where the transparent title bar sits) still reach Flutter's buttons and are not eaten as window drags. *Task 4: manual check, with the fix if it fails.*

---

### Task 1: Window state model (pure Dart)

**Files:**
- Create: `lib/ui/window/window_state.dart`
- Test: `test/window_state_test.dart`

**Interfaces:**
- Produces:
  - `enum WindowButton { minimize, maximize, close }`
  - `class ButtonLayout { const ButtonLayout({List<WindowButton> leading, List<WindowButton> trailing}); static const none, apple, windows; bool get isEmpty; static ButtonLayout parseGtk(String); }`
  - `bool isTilingWm({String? wmName, Map<String, String> env, bool tiled})`
  - `class WindowState { const WindowState({bool maximized, bool fullscreen, bool focused, bool maxHovered, ButtonLayout layout}); static const hidden; factory WindowState.fromPlatform(TargetPlatform, Map<Object?, Object?>); }`
  - Both classes have value equality.

- [ ] **Step 1: Write the failing tests**

`test/window_state_test.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/window/window_state.dart';

const _min = WindowButton.minimize;
const _max = WindowButton.maximize;
const _close = WindowButton.close;

void main() {
  group('ButtonLayout.parseGtk', () {
    test("GNOME's default is close alone on the right", () {
      expect(
        ButtonLayout.parseGtk('appmenu:close'),
        const ButtonLayout(trailing: [_close]),
      );
    });

    test('buttons before the colon go on the left, in order', () {
      expect(
        ButtonLayout.parseGtk('close,minimize,maximize:'),
        const ButtonLayout(leading: [_close, _min, _max]),
      );
    });

    test('both sides at once', () {
      expect(
        ButtonLayout.parseGtk('close:minimize,maximize'),
        const ButtonLayout(leading: [_close], trailing: [_min, _max]),
      );
    });

    test('no colon puts everything on the left, as GTK reads it', () {
      expect(
        ButtonLayout.parseGtk('minimize,close'),
        const ButtonLayout(leading: [_min, _close]),
      );
    });

    test('names Loaf does not draw are dropped, whitespace ignored', () {
      expect(
        ButtonLayout.parseGtk(' icon , menu :spacer, minimize ,close '),
        const ButtonLayout(trailing: [_min, _close]),
      );
    });

    test('a button named twice appears once', () {
      expect(
        ButtonLayout.parseGtk(':close,close'),
        const ButtonLayout(trailing: [_close]),
      );
    });

    test('empty and nonsense layouts have no buttons', () {
      expect(ButtonLayout.parseGtk('').isEmpty, isTrue);
      expect(ButtonLayout.parseGtk(':').isEmpty, isTrue);
      expect(ButtonLayout.parseGtk('appmenu:icon').isEmpty, isTrue);
    });
  });

  group('isTilingWm', () {
    test('a compositor socket means tiling', () {
      for (final name in [
        'SWAYSOCK',
        'HYPRLAND_INSTANCE_SIGNATURE',
        'NIRI_SOCKET',
        'I3SOCK',
      ]) {
        expect(isTilingWm(env: {name: '/run/x'}), isTrue, reason: name);
      }
    });

    test('an empty socket variable does not count', () {
      expect(isTilingWm(env: {'SWAYSOCK': ''}), isFalse);
    });

    test('XDG_CURRENT_DESKTOP is read per entry, any case', () {
      expect(isTilingWm(env: {'XDG_CURRENT_DESKTOP': 'sway:wlroots'}), isTrue);
      expect(isTilingWm(env: {'XDG_CURRENT_DESKTOP': 'Hyprland'}), isTrue);
      expect(isTilingWm(env: {'XDG_CURRENT_DESKTOP': 'river'}), isTrue);
    });

    test('X11 tiling WMs by name', () {
      for (final name in ['i3', 'bspwm', 'awesome', 'LG3D', 'herbstluftwm']) {
        expect(isTilingWm(wmName: name), isTrue, reason: name);
      }
    });

    test('a window tiled on all four edges counts, whatever the WM', () {
      expect(isTilingWm(tiled: true), isTrue);
    });

    test('stacking desktops are not tiling', () {
      expect(isTilingWm(env: {'XDG_CURRENT_DESKTOP': 'GNOME'}), isFalse);
      expect(isTilingWm(env: {'XDG_CURRENT_DESKTOP': 'KDE'}), isFalse);
      expect(isTilingWm(wmName: 'GNOME Shell'), isFalse);
      expect(isTilingWm(wmName: 'KWin'), isFalse);
      expect(isTilingWm(), isFalse);
    });
  });

  group('WindowState.fromPlatform', () {
    test('macOS: three buttons on the left, none in fullscreen', () {
      expect(
        WindowState.fromPlatform(TargetPlatform.macOS, const {}).layout,
        ButtonLayout.apple,
      );
      expect(
        WindowState.fromPlatform(TargetPlatform.macOS, const {
          'fullscreen': true,
        }).layout.isEmpty,
        isTrue,
      );
    });

    test('Windows: three buttons on the right, maximize hover carried', () {
      final s = WindowState.fromPlatform(TargetPlatform.windows, const {
        'maximized': true,
        'maxHovered': true,
      });
      expect(s.layout, ButtonLayout.windows);
      expect(s.maximized, isTrue);
      expect(s.maxHovered, isTrue);
    });

    test('Linux: the layout GTK reports', () {
      expect(
        WindowState.fromPlatform(TargetPlatform.linux, const {
          'decorationLayout': 'appmenu:close',
          'env': {'XDG_CURRENT_DESKTOP': 'GNOME'},
        }).layout,
        const ButtonLayout(trailing: [_close]),
      );
    });

    test('Linux: no layout reported falls back to GTK\'s own default', () {
      expect(
        WindowState.fromPlatform(TargetPlatform.linux, const {}).layout,
        const ButtonLayout(trailing: [_min, _max, _close]),
      );
    });

    test('Linux: a tiling WM has no buttons', () {
      expect(
        WindowState.fromPlatform(TargetPlatform.linux, const {
          'decorationLayout': ':minimize,maximize,close',
          'env': {'SWAYSOCK': '/run/sway'},
        }).layout.isEmpty,
        isTrue,
      );
      expect(
        WindowState.fromPlatform(TargetPlatform.linux, const {
          'decorationLayout': ':close',
          'wmName': 'i3',
        }).layout.isEmpty,
        isTrue,
      );
    });

    test('focused unless the runner says otherwise', () {
      expect(
        WindowState.fromPlatform(TargetPlatform.macOS, const {}).focused,
        isTrue,
      );
      expect(
        WindowState.fromPlatform(TargetPlatform.macOS, const {
          'focused': false,
        }).focused,
        isFalse,
      );
    });

    test('phones have no buttons', () {
      expect(
        WindowState.fromPlatform(TargetPlatform.iOS, const {}).layout.isEmpty,
        isTrue,
      );
    });

    test('equal maps make equal states', () {
      const m = {'maximized': true};
      expect(
        WindowState.fromPlatform(TargetPlatform.windows, m),
        WindowState.fromPlatform(TargetPlatform.windows, m),
      );
    });
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- flutter test test/window_state_test.dart`
Expected: FAIL — `window_state.dart` does not exist.

- [ ] **Step 3: Implement `lib/ui/window/window_state.dart`**

```dart
/// Which window buttons Loaf draws, on which side, and the state they show.
///
/// Pure: the runner reports raw facts (its WM's name, the environment, GTK's
/// button layout) and the rules that turn them into buttons live here,
/// where they can be tested without a window.
library;

import 'package:flutter/foundation.dart';

enum WindowButton { minimize, maximize, close }

/// The buttons at the window's leading (left) and trailing (right) top
/// corners.
@immutable
class ButtonLayout {
  const ButtonLayout({this.leading = const [], this.trailing = const []});

  static const none = ButtonLayout();

  /// Close, minimize, zoom, on the left: where a Mac keeps them.
  static const apple = ButtonLayout(
    leading: [WindowButton.close, WindowButton.minimize, WindowButton.maximize],
  );

  /// Minimize, maximize, close, on the right: where Windows keeps them.
  static const windows = ButtonLayout(
    trailing: [
      WindowButton.minimize,
      WindowButton.maximize,
      WindowButton.close,
    ],
  );

  final List<WindowButton> leading;
  final List<WindowButton> trailing;

  bool get isEmpty => leading.isEmpty && trailing.isEmpty;

  static const _gtkNames = {
    'minimize': WindowButton.minimize,
    'maximize': WindowButton.maximize,
    'close': WindowButton.close,
  };

  /// Reads GTK's `gtk-decoration-layout`, e.g. `appmenu:minimize,close`.
  /// The user's desktop sets it, so honouring it puts Loaf's buttons where
  /// every other app on that desktop has them. Names Loaf does not draw
  /// (icon, menu, appmenu, spacer) are dropped, and so is a button named a
  /// second time.
  static ButtonLayout parseGtk(String layout) {
    final seen = <WindowButton>{};
    List<WindowButton> side(String names) => [
      for (final name in names.split(','))
        if (_gtkNames[name.trim()] case final button? when seen.add(button))
          button,
    ];
    final colon = layout.indexOf(':');
    // Without a colon GTK puts everything on the left.
    if (colon < 0) return ButtonLayout(leading: side(layout));
    return ButtonLayout(
      leading: side(layout.substring(0, colon)),
      trailing: side(layout.substring(colon + 1)),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ButtonLayout &&
      listEquals(other.leading, leading) &&
      listEquals(other.trailing, trailing);

  @override
  int get hashCode => Object.hash(Object.hashAll(leading), Object.hashAll(trailing));

  @override
  String toString() => 'ButtonLayout($leading : $trailing)';
}

const _tilingSockets = [
  'SWAYSOCK',
  'HYPRLAND_INSTANCE_SIGNATURE',
  'NIRI_SOCKET',
  'I3SOCK',
];

const _tilingDesktops = {
  'sway', 'hyprland', 'niri', 'river', 'i3', 'bspwm', 'qtile', 'awesome',
  'dwm', 'xmonad', 'herbstluftwm',
};

// LG3D is what dwm and xmonad commonly advertise, to get Java apps drawing.
const _tilingWmNames = {
  'i3', 'bspwm', 'awesome', 'dwm', 'xmonad', 'herbstluftwm', 'qtile', 'lg3d',
  'spectrwm', 'leftwm',
};

/// Whether a tiling window manager is placing this window. Its user moves,
/// sizes and closes windows from the keyboard, so window buttons would only
/// be clutter. Known WMs are recognised by their socket, desktop name or
/// X11 name; an unknown one still counts while it has the window tiled on
/// all four edges (GNOME's half-snap tiles three, so it keeps its buttons).
bool isTilingWm({
  String? wmName,
  Map<String, String> env = const {},
  bool tiled = false,
}) {
  if (tiled) return true;
  if (_tilingSockets.any((name) => (env[name] ?? '').isNotEmpty)) return true;
  final desktops = (env['XDG_CURRENT_DESKTOP'] ?? '')
      .split(':')
      .map((d) => d.trim().toLowerCase());
  if (desktops.any(_tilingDesktops.contains)) return true;
  return wmName != null && _tilingWmNames.contains(wmName.toLowerCase());
}

/// What the runner last said about the window, and the buttons that follow.
@immutable
class WindowState {
  const WindowState({
    this.maximized = false,
    this.fullscreen = false,
    this.focused = true,
    this.maxHovered = false,
    this.layout = ButtonLayout.none,
  });

  /// Before the runner answers, and on every phone: no buttons.
  static const hidden = WindowState();

  // GTK's own default, for a desktop that sets nothing.
  static const _gtkDefault = 'menu:minimize,maximize,close';

  factory WindowState.fromPlatform(
    TargetPlatform platform,
    Map<Object?, Object?> m,
  ) {
    final fullscreen = m['fullscreen'] == true;
    final env = <String, String>{
      for (final MapEntry(:key, :value)
          in ((m['env'] as Map?) ?? const {}).entries)
        '$key': '$value',
    };
    // A fullscreen window has no title bar to put buttons in, on any OS.
    final layout = fullscreen
        ? ButtonLayout.none
        : switch (platform) {
            TargetPlatform.macOS => ButtonLayout.apple,
            TargetPlatform.windows => ButtonLayout.windows,
            TargetPlatform.linux =>
              isTilingWm(
                    wmName: m['wmName'] as String?,
                    env: env,
                    tiled: m['tiled'] == true,
                  )
                  ? ButtonLayout.none
                  : ButtonLayout.parseGtk(
                      m['decorationLayout'] as String? ?? _gtkDefault,
                    ),
            _ => ButtonLayout.none,
          };
    return WindowState(
      maximized: m['maximized'] == true,
      fullscreen: fullscreen,
      focused: m['focused'] != false,
      maxHovered: m['maxHovered'] == true,
      layout: layout,
    );
  }

  /// Whether the window is focused; unfocused buttons dim, as the OS's do.
  final bool focused;
  final bool maximized;
  final bool fullscreen;

  /// Windows only: the pointer is over the maximize button. Windows routes
  /// that spot to the frame so it can show snap layouts, so Flutter never
  /// sees the hover and the runner reports it instead.
  final bool maxHovered;
  final ButtonLayout layout;

  @override
  bool operator ==(Object other) =>
      other is WindowState &&
      other.maximized == maximized &&
      other.fullscreen == fullscreen &&
      other.focused == focused &&
      other.maxHovered == maxHovered &&
      other.layout == layout;

  @override
  int get hashCode =>
      Object.hash(maximized, fullscreen, focused, maxHovered, layout);
}
```

Run `mise exec -- dart format lib/ui/window test/window_state_test.dart` after writing, since the `const` sets above are deliberately compact.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- flutter test test/window_state_test.dart`
Expected: PASS (all).

- [ ] **Step 5: Analyze and commit**

```bash
mise exec -- flutter analyze lib/ui/window test/window_state_test.dart
git add lib/ui/window/window_state.dart test/window_state_test.dart
git commit -m "feat(window): which buttons go where, from what the runner reports

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Controller and chrome widgets

**Files:**
- Create: `lib/ui/window/window_chrome.dart`
- Test: `test/window_chrome_test.dart`

**Interfaces:**
- Consumes (from Task 1): `WindowState`, `WindowState.fromPlatform`, `WindowState.hidden`, `ButtonLayout`, `WindowButton`.
- Produces:
  - `class WindowChromeController extends ChangeNotifier { WindowChromeController({MethodChannel channel}); WindowState get state; Future<void> start(); Future<void> minimize(); Future<void> toggleMaximize(); Future<void> close(); Future<void> startDrag(); Future<void> titlebarDoubleClick(); Future<void> setMaxButtonRect(Rect); }`
  - `class WindowChrome extends InheritedNotifier<WindowChromeController> { const WindowChrome({required WindowChromeController controller, required Widget child}); static WindowChromeController? maybeOf(BuildContext); static List<WindowButton> buttonsAt(BuildContext, WindowEdge); }`
  - `enum WindowEdge { leading, trailing }`
  - `class WindowEdges extends InheritedWidget { const WindowEdges({required bool leading, required bool trailing, required Widget child}); const WindowEdges.none({required Widget child}); }`
  - `abstract final class WindowMetrics { static const band = 56.0; }`
  - `class WindowDragArea extends StatelessWidget { const WindowDragArea({required Widget child}); }`
  - `class WindowControls extends StatelessWidget { const WindowControls(WindowEdge edge); }`
  - `class WindowBand extends StatelessWidget { const WindowBand(); }`

- [ ] **Step 1: Write the failing tests**

`test/window_chrome_test.dart`:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/window/window_chrome.dart';
import 'package:loaf_native/ui/window/window_state.dart';

const _channel = MethodChannel('loaf/window');

/// Fakes the runner: answers `state` with [state] and records every call.
List<MethodCall> _fakeRunner(
  WidgetTester tester, [
  Map<String, Object?> state = const {},
]) {
  final calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
    call,
  ) async {
    calls.add(call);
    return call.method == 'state' ? state : null;
  });
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      null,
    ),
  );
  return calls;
}

/// Sends `stateChanged` as the runner would.
Future<void> _runnerSays(WidgetTester tester, Map<String, Object?> state) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    _channel.name,
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('stateChanged', state),
    ),
    (_) {},
  );
  await tester.pump();
}

Future<WindowChromeController> _pump(WidgetTester tester, Widget child) async {
  final controller = WindowChromeController();
  addTearDown(controller.dispose);
  await controller.start();
  await tester.pumpWidget(
    MaterialApp(
      theme: loafDarkTheme(),
      builder: (context, app) =>
          WindowChrome(controller: controller, child: app!),
      home: Scaffold(body: child),
    ),
  );
  return controller;
}

/// A header the way the app's headers use the chrome.
Widget _header({VoidCallback? onButton}) => WindowDragArea(
  child: SizedBox(
    height: WindowMetrics.band,
    child: Row(
      children: [
        const WindowControls(WindowEdge.leading),
        const Expanded(child: Text('general')),
        IconButton(
          key: const ValueKey('header-button'),
          onPressed: onButton,
          icon: const Icon(Icons.people),
        ),
        const WindowControls(WindowEdge.trailing),
      ],
    ),
  ),
);

void main() {
  testWidgets(
    'each button sends its own call',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final calls = _fakeRunner(tester);
      await _pump(tester, _header());
      await tester.pump();

      for (final name in ['minimize', 'maximize', 'close']) {
        await tester.tap(find.byKey(ValueKey('window-$name')));
        await tester.pump();
      }
      expect(calls.map((c) => c.method), containsAllInOrder([
        'minimize',
        'toggleMaximize',
        'close',
      ]));
    },
  );

  testWidgets(
    'macOS draws its dots on the left',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      _fakeRunner(tester);
      await _pump(tester, _header());
      await tester.pump();

      final close = tester.getCenter(find.byKey(const ValueKey('window-close')));
      final title = tester.getCenter(find.text('general'));
      expect(close.dx, lessThan(title.dx));
    },
  );

  testWidgets(
    'dragging the bar moves the window, double-clicking it zooms',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      final calls = _fakeRunner(tester, {'decorationLayout': ':close'});
      await _pump(tester, _header());
      await tester.pump();

      await tester.drag(
        find.text('general'),
        const Offset(80, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), contains('startDrag'));

      calls.clear();
      final title = find.text('general');
      await tester.tap(title, kind: PointerDeviceKind.mouse);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(title, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), contains('titlebarDoubleClick'));
    },
  );

  testWidgets(
    'a button inside a drag area takes its tap at once',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      final calls = _fakeRunner(tester, {'decorationLayout': ':close'});
      var pressed = 0;
      await _pump(tester, _header(onButton: () => pressed++));
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('header-button')),
        kind: PointerDeviceKind.mouse,
      );
      // No waiting out a double-tap timeout: one frame is enough.
      await tester.pump();
      expect(pressed, 1);
      expect(
        calls.map((c) => c.method),
        isNot(anyOf(contains('startDrag'), contains('titlebarDoubleClick'))),
      );
    },
  );

  testWidgets(
    'the GTK layout decides the side, and a tiling WM shows nothing',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      _fakeRunner(tester, {'decorationLayout': 'close:'});
      await _pump(tester, _header());
      await tester.pump();

      final close = tester.getCenter(find.byKey(const ValueKey('window-close')));
      expect(close.dx, lessThan(tester.getCenter(find.text('general')).dx));
      expect(find.byKey(const ValueKey('window-minimize')), findsNothing);

      await _runnerSays(tester, {
        'decorationLayout': 'close:',
        'env': {'SWAYSOCK': '/run/sway'},
      });
      expect(find.byKey(const ValueKey('window-close')), findsNothing);
    },
  );

  testWidgets(
    'maximized swaps the maximize icon for restore',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      _fakeRunner(tester);
      final controller = await _pump(tester, _header());
      await tester.pump();
      expect(controller.state.maximized, isFalse);
      final before = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('window-maximize')),
          matching: find.byType(Icon),
        ),
      );

      await _runnerSays(tester, {'maximized': true});
      final after = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('window-maximize')),
          matching: find.byType(Icon),
        ),
      );
      expect(after.icon, isNot(before.icon));
    },
  );

  testWidgets(
    'WindowEdges.none keeps a covered surface from drawing buttons',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      _fakeRunner(tester);
      await _pump(tester, WindowEdges.none(child: _header()));
      await tester.pump();
      expect(find.byKey(const ValueKey('window-close')), findsNothing);
    },
  );

  testWidgets(
    'WindowBand takes no room where its corner has no buttons',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      _fakeRunner(tester, {'decorationLayout': ':close'});
      await _pump(
        tester,
        const Column(
          children: [
            WindowEdges(leading: true, trailing: false, child: WindowBand()),
            WindowEdges(leading: false, trailing: true, child: WindowBand()),
          ],
        ),
      );
      await tester.pump();
      final bands = tester.renderObjectList<RenderBox>(find.byType(WindowBand));
      expect([for (final b in bands) b.size.height], [0, WindowMetrics.band]);
    },
  );

  testWidgets(
    'Windows reports the maximize button to the runner',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final calls = _fakeRunner(tester);
      await _pump(tester, _header());
      await tester.pump();
      await tester.pump();
      final rect = calls.lastWhere((c) => c.method == 'setMaxButtonRect');
      final box = tester.getRect(find.byKey(const ValueKey('window-maximize')));
      expect((rect.arguments as Map)['x'], box.left);
      expect((rect.arguments as Map)['w'], box.width);
    },
  );

  testWidgets(
    'a missing runner is quietly no buttons',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      // No mock handler: invoking throws MissingPluginException.
      final controller = await _pump(tester, _header());
      await tester.pump();
      expect(controller.state, WindowState.hidden);
      expect(find.byKey(const ValueKey('window-close')), findsNothing);
      await controller.close(); // must not throw
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nothing on a phone', (tester) async {
    // The default test platform is Android.
    final calls = _fakeRunner(tester, {'decorationLayout': ':close'});
    await _pump(tester, _header());
    await tester.pump();
    expect(calls, isEmpty);
    expect(find.byKey(const ValueKey('window-close')), findsNothing);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- flutter test test/window_chrome_test.dart`
Expected: FAIL — `window_chrome.dart` does not exist.

- [ ] **Step 3: Implement `lib/ui/window/window_chrome.dart`**

```dart
/// Loaf's own window controls, where the OS title bar used to be.
///
/// The runners hide their frames and answer `loaf/window`; everything a
/// person sees and clicks is drawn here, in the app's palette. Behaviour
/// stays the OS's: a drag is the OS's own window move (so snapping works),
/// and a double-click does what the OS's title bar would.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../platform.dart';
import '../theme/loaf_theme.dart';
import 'window_state.dart';

export 'window_state.dart' show WindowButton, WindowState;

/// Talks to the runner's window: sends what the buttons ask for, and keeps
/// the [state] it reports.
class WindowChromeController extends ChangeNotifier {
  WindowChromeController({
    MethodChannel channel = const MethodChannel('loaf/window'),
  }) : _channel = channel;

  final MethodChannel _channel;
  WindowState _state = WindowState.hidden;
  bool _disposed = false;

  WindowState get state => _state;

  /// Asks the runner where things stand and listens for changes. On a phone,
  /// or under a runner without the channel, the window stays
  /// [WindowState.hidden]: no buttons, which is what those cases want.
  Future<void> start() async {
    if (!isDesktop) return;
    _channel.setMethodCallHandler(_onCall);
    try {
      _apply(await _channel.invokeMapMethod<Object?, Object?>('state'));
    } on MissingPluginException {
      // A runner that predates the channel keeps its own frame.
    } on PlatformException catch (e) {
      debugPrint('[loaf window] no window state: $e');
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'stateChanged') _apply(call.arguments as Map?);
    return null;
  }

  void _apply(Map<Object?, Object?>? report) {
    if (report == null || _disposed) return;
    final next = WindowState.fromPlatform(defaultTargetPlatform, report);
    if (next == _state) return;
    _state = next;
    notifyListeners();
  }

  Future<void> minimize() => _send('minimize');
  Future<void> toggleMaximize() => _send('toggleMaximize');
  Future<void> close() => _send('close');
  Future<void> startDrag() => _send('startDrag');
  Future<void> titlebarDoubleClick() => _send('titlebarDoubleClick');

  /// Where the maximize button is, in logical pixels from the window's
  /// top-left. Windows needs it to offer snap layouts over that button.
  Future<void> setMaxButtonRect(Rect r) => _send('setMaxButtonRect', {
    'x': r.left,
    'y': r.top,
    'w': r.width,
    'h': r.height,
  });

  // A button that does nothing beats an exception on every click.
  Future<void> _send(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No runner channel: nothing to tell.
    } on PlatformException catch (e) {
      debugPrint('[loaf window] $method failed: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

/// Puts the window's controller where every surface can reach it. Installed
/// in `MaterialApp.builder`, so it covers every route.
class WindowChrome extends InheritedNotifier<WindowChromeController> {
  const WindowChrome({
    super.key,
    required WindowChromeController controller,
    required super.child,
  }) : super(notifier: controller);

  static WindowChromeController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WindowChrome>()?.notifier;

  /// The buttons a surface here should draw at [edge]: the window's buttons
  /// for that corner, if this surface touches it.
  static List<WindowButton> buttonsAt(BuildContext context, WindowEdge edge) {
    final controller = maybeOf(context);
    if (controller == null || !isDesktop) return const [];
    final edges = WindowEdges._of(context);
    final layout = controller.state.layout;
    return switch (edge) {
      WindowEdge.leading when edges.leading => layout.leading,
      WindowEdge.trailing when edges.trailing => layout.trailing,
      _ => const [],
    };
  }
}

enum WindowEdge { leading, trailing }

/// Which top corners of the window the surface below touches. The shell
/// sets it per column, so exactly one surface draws each corner's buttons;
/// a surface outside any (sign-in, a fullscreen viewer) is the whole window
/// and touches both.
class WindowEdges extends InheritedWidget {
  const WindowEdges({
    super.key,
    required this.leading,
    required this.trailing,
    required super.child,
  });

  /// For a surface that touches neither corner, such as a drawer sliding
  /// over the page that already holds the buttons.
  const WindowEdges.none({super.key, required super.child})
    : leading = false,
      trailing = false;

  final bool leading;
  final bool trailing;

  static const _whole = WindowEdges(
    leading: true,
    trailing: true,
    child: SizedBox.shrink(),
  );

  static WindowEdges _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WindowEdges>() ?? _whole;

  @override
  bool updateShouldNotify(WindowEdges old) =>
      old.leading != leading || old.trailing != trailing;
}

abstract final class WindowMetrics {
  /// A band on a surface with no bar of its own is as tall as the headers
  /// beside it, so the buttons line up across columns.
  static const band = 56.0;
}

/// Makes [child], a bar, the window's title bar: dragging it moves the
/// window, double-clicking it does what the OS's title bar would.
///
/// One recognizer does both, and it never holds the gesture arena, so a
/// button inside the bar still takes its click at once: a double-tap
/// recognizer here would delay every button in every header by the
/// double-tap timeout.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final controller = WindowChrome.maybeOf(context);
    if (controller == null || !isDesktop) return child;
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        TapAndPanGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapAndPanGestureRecognizer>(
              () => TapAndPanGestureRecognizer(debugOwner: this),
              (r) => r
                ..onTapUp = (details) {
                  if (details.consecutiveTapCount == 2) {
                    controller.titlebarDoubleClick();
                  }
                }
                ..onDragStart = (_) => controller.startDrag(),
            ),
      },
      child: child,
    );
  }
}

/// The window's buttons for one corner, if the surface here touches it.
/// Draws nothing otherwise, so headers can always include both.
class WindowControls extends StatelessWidget {
  const WindowControls(this.edge, {super.key, this.inBand = false});

  final WindowEdge edge;

  /// In a [WindowBand], which pads itself; in a bar, the buttons keep a gap
  /// from the bar's own contents.
  final bool inBand;

  @override
  Widget build(BuildContext context) {
    final buttons = WindowChrome.buttonsAt(context, edge);
    if (buttons.isEmpty) return const SizedBox.shrink();
    final controller = WindowChrome.maybeOf(context)!;
    return defaultTargetPlatform == TargetPlatform.macOS
        ? _TrafficLights(controller: controller, buttons: buttons, gap: !inBand)
        : _Pills(
            controller: controller,
            buttons: buttons,
            edge: edge,
            gap: !inBand,
          );
  }
}

/// The top of a surface with no bar of its own (the rail, the member list,
/// sign-in), where it holds the window's buttons: a draggable band as tall
/// as the headers beside it. Takes no room where its corners have none.
class WindowBand extends StatelessWidget {
  const WindowBand({super.key});

  @override
  Widget build(BuildContext context) {
    final leading = WindowChrome.buttonsAt(context, WindowEdge.leading);
    final trailing = WindowChrome.buttonsAt(context, WindowEdge.trailing);
    if (leading.isEmpty && trailing.isEmpty) return const SizedBox.shrink();
    // The rail is 76pt: the dots fit exactly, and pills (Linux with its
    // buttons on the left) shrink to fit rather than overflow.
    return WindowDragArea(
      child: SizedBox(
        height: WindowMetrics.band,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
          child: Row(
            children: [
              if (leading.isNotEmpty)
                const Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: WindowControls(WindowEdge.leading, inBand: true),
                  ),
                ),
              const Spacer(),
              if (trailing.isNotEmpty)
                const Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: WindowControls(WindowEdge.trailing, inBand: true),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

VoidCallback _action(WindowChromeController c, WindowButton b) =>
    switch (b) {
      WindowButton.minimize => c.minimize,
      WindowButton.maximize => c.toggleMaximize,
      WindowButton.close => c.close,
    };

/// A Mac's three dots, in Loaf's palette: quiet at rest, coloured with
/// their glyphs while the pointer is over any of them.
class _TrafficLights extends StatefulWidget {
  const _TrafficLights({
    required this.controller,
    required this.buttons,
    required this.gap,
  });

  final WindowChromeController controller;
  final List<WindowButton> buttons;
  final bool gap;

  @override
  State<_TrafficLights> createState() => _TrafficLightsState();
}

class _TrafficLightsState extends State<_TrafficLights> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    final focused = widget.controller.state.focused;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: EdgeInsets.only(right: widget.gap ? LoafSpace.x3 : 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, b) in widget.buttons.indexed) ...[
              if (i > 0) const SizedBox(width: LoafSpace.x2),
              GestureDetector(
                key: ValueKey('window-${b.name}'),
                onTap: _action(widget.controller, b),
                child: AnimatedContainer(
                  duration: LoafMotion.fast,
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _hover
                        ? switch (b) {
                            WindowButton.close => tokens.accent,
                            WindowButton.minimize => tokens.idle,
                            WindowButton.maximize => tokens.online,
                          }
                        : focused
                        ? tokens.textMuted.withValues(alpha: 0.55)
                        : tokens.border,
                  ),
                  child: _hover
                      ? Icon(
                          switch (b) {
                            WindowButton.close => LucideIcons.x,
                            WindowButton.minimize => LucideIcons.minus,
                            WindowButton.maximize => LucideIcons.plus,
                          },
                          size: 8,
                          color: tokens.textOnAccent,
                        )
                      : null,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Linux and Windows: icon pills, close turning accent red under the
/// pointer, the way those desktops make close the loud one.
class _Pills extends StatelessWidget {
  const _Pills({
    required this.controller,
    required this.buttons,
    required this.edge,
    required this.gap,
  });

  final WindowChromeController controller;
  final List<WindowButton> buttons;
  final WindowEdge edge;
  final bool gap;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    return Padding(
      padding: !gap
          ? EdgeInsets.zero
          : edge == WindowEdge.trailing
          ? const EdgeInsets.only(left: LoafSpace.x2)
          : const EdgeInsets.only(right: LoafSpace.x2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, b) in buttons.indexed) ...[
            if (i > 0) const SizedBox(width: 2),
            _Pill(
              key: ValueKey('window-${b.name}'),
              button: b,
              state: state,
              onTap: _action(controller, b),
              onPlaced:
                  b == WindowButton.maximize &&
                      defaultTargetPlatform == TargetPlatform.windows
                  ? controller.setMaxButtonRect
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

class _Pill extends StatefulWidget {
  const _Pill({
    super.key,
    required this.button,
    required this.state,
    required this.onTap,
    this.onPlaced,
  });

  final WindowButton button;
  final WindowState state;
  final VoidCallback onTap;

  /// Told where this button sits after each layout, and [Rect.zero] when it
  /// goes, so the runner never claims a spot no button holds.
  final ValueChanged<Rect>? onPlaced;

  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> {
  bool _hover = false;
  Rect? _placed;

  void _report(Duration _) {
    final onPlaced = widget.onPlaced;
    final box = context.findRenderObject() as RenderBox?;
    if (!mounted || onPlaced == null || box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect == _placed) return;
    _placed = rect;
    onPlaced(rect);
  }

  @override
  void dispose() {
    if (_placed != null) widget.onPlaced?.call(Rect.zero);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onPlaced != null) {
      SchedulerBinding.instance.addPostFrameCallback(_report);
    }
    final tokens = LoafTokens.of(context);
    final close = widget.button == WindowButton.close;
    final hover =
        _hover ||
        (widget.button == WindowButton.maximize && widget.state.maxHovered);
    final icon = switch (widget.button) {
      WindowButton.minimize => LucideIcons.minus,
      WindowButton.maximize =>
        widget.state.maximized ? LucideIcons.copy : LucideIcons.square,
      WindowButton.close => LucideIcons.x,
    };
    final rest = widget.state.focused
        ? tokens.textMuted
        : tokens.textMuted.withValues(alpha: 0.5);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: LoafMotion.fast,
          width: 32,
          height: 28,
          decoration: BoxDecoration(
            color: hover
                ? (close ? tokens.accent : tokens.card)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(LoafRadius.md),
          ),
          child: Icon(
            icon,
            size: 16,
            color: hover && close ? tokens.textOnAccent : rest,
          ),
        ),
      ),
    );
  }
}
```

Notes for the implementer:
- `TapAndPanGestureRecognizer`, `TapDragUpDetails.consecutiveTapCount` and `onDragStart` come from `package:flutter/gestures.dart` (`tap_and_drag.dart`). Check the exact field names against the pinned SDK at `$(mise where flutter)/packages/flutter/lib/src/gestures/tap_and_drag.dart` before relying on them.
- If `flutter analyze` flags the `scheduler.dart` import as unnecessary, because `SchedulerBinding` is re-exported, drop it.
- Pill clicks use `GestureDetector`, not `InkWell`. These are window chrome: no ink splash and no press scale.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- flutter test test/window_chrome_test.dart test/window_state_test.dart`
Expected: PASS (all). If the double-click test fails because the two taps are read as one long press or as a drag, check `TapAndPanGestureRecognizer`'s consecutive-tap timeout in the SDK source and adjust the gap between taps in the *test* (it must stay under `kDoubleTapTimeout`). Do not change the recognizer.

- [ ] **Step 5: Analyze and commit**

```bash
mise exec -- flutter analyze lib/ui/window test/window_chrome_test.dart
git add lib/ui/window/window_chrome.dart test/window_chrome_test.dart
git commit -m "feat(window): Loaf's own window buttons and title-bar drag

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Put the chrome on every surface

**Files:**
- Modify: `lib/main.dart` (controller, `MaterialApp.builder`)
- Modify: `lib/ui/shell/app_shell.dart` (`WindowEdges` per column and drawer, around lines 1097–1165)
- Modify: `lib/ui/shell/spaces_rail.dart` (band above the loaf mark, around line 70)
- Modify: `lib/ui/shell/channel_list.dart` (`_Header` is a drag area, line 153)
- Modify: `lib/ui/members/member_list.dart` (band at the top, line 63)
- Modify: `lib/ui/channel/channel_view.dart` (`_ChannelHeader`, line 197)
- Modify: `lib/ui/shell/shell_faces.dart` (`_Face`, line 76)
- Modify: `lib/ui/home/invite_preview.dart` (header, line 53)
- Modify: `lib/ui/call/voice_channel_page.dart` (header, line 105)
- Modify: `lib/ui/call/call_view.dart` (`CallTopBar`, line 244)
- Modify: `lib/ui/channel/image_viewer.dart` (`_Bar`, line 80)
- Modify: `lib/ui/auth/login_page.dart` (band at the top, line 112)
- Modify: `docs/superpowers/specs/2026-10-06-window-chrome-design.md`
- Test: `test/window_placement_test.dart`

**Interfaces:**
- Consumes (Task 2): `WindowChromeController`, `WindowChrome`, `WindowEdges`, `WindowEdges.none`, `WindowDragArea`, `WindowControls(WindowEdge.leading|trailing)`, `WindowBand`.

**The pattern.** Every 56pt-style bar (also `CallTopBar`'s 44pt compact form) changes the same way:
- wrap the bar's outer `Container` in `WindowDragArea`
- add `const WindowControls(WindowEdge.leading)` as the first child of its `Row`
- add `const WindowControls(WindowEdge.trailing)` as the last child

For example, in `_ChannelHeader.build`:

```dart
    return WindowDragArea(
      child: Container(
        height: 56,
        // …unchanged decoration and padding…
        child: LayoutBuilder(
          builder: (context, constraints) {
            // …
            return Row(
              children: [
                const WindowControls(WindowEdge.leading),
                // …existing children unchanged…
                const WindowControls(WindowEdge.trailing),
              ],
            );
          },
        ),
      ),
    );
```

Surfaces with no bar get `const WindowBand()` as the first child of a `Column` at their top, *outside* any `SafeArea` or padding.

- [ ] **Step 1: Write the failing placement tests**

`test/window_placement_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:loaf_native/ui/auth/login_page.dart';
import 'package:loaf_native/ui/shell/app_shell.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/window/window_chrome.dart';

const _channel = MethodChannel('loaf/window');
const _close = ValueKey('window-close');

Future<void> _pump(
  WidgetTester tester,
  Size size,
  Widget home, [
  Map<String, Object?> state = const {},
]) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    _channel,
    (call) async => call.method == 'state' ? state : null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      null,
    ),
  );
  final controller = WindowChromeController();
  addTearDown(controller.dispose);
  await controller.start();
  await tester.pumpWidget(
    MaterialApp(
      theme: loafLightTheme(),
      darkTheme: loafDarkTheme(),
      themeMode: ThemeMode.dark,
      builder: (context, app) =>
          WindowChrome(controller: controller, child: app!),
      home: home,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'wide, members open: one close, at the top right of the member list',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      await _pump(tester, const Size(1440, 900), const AppShell());
      expect(find.byKey(_close), findsOneWidget);
      final close = tester.getRect(find.byKey(_close));
      expect(close.right, greaterThan(1440 - LoafShell.memberListWidth));
      expect(close.top, lessThan(WindowMetrics.band));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wide, members closed: the close moves into the channel header',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      await _pump(tester, const Size(1440, 900), const AppShell());
      await tester.tap(find.byIcon(LucideIcons.users));
      await tester.pumpAndSettle();
      expect(find.byKey(_close), findsOneWidget);
      final close = tester.getRect(find.byKey(_close));
      final members = tester.getRect(find.byIcon(LucideIcons.users));
      // Past the members toggle, at the window's right edge.
      expect(close.left, greaterThan(members.right));
      expect(close.right, greaterThan(1440 - 60));
    },
  );

  testWidgets(
    'macOS wide: the dots sit in the rail',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      await _pump(tester, const Size(1440, 900), const AppShell());
      expect(find.byKey(_close), findsOneWidget);
      final close = tester.getRect(find.byKey(_close));
      expect(close.right, lessThan(LoafShell.railWidth));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow: one set of buttons, in the channel header',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      await _pump(tester, const Size(600, 800), const AppShell());
      expect(find.byKey(_close), findsOneWidget);
      final close = tester.getRect(find.byKey(_close));
      final menu = tester.getRect(find.byIcon(LucideIcons.menu));
      expect(close.right, lessThan(menu.left));

      // The drawer slides over the header; it brings no buttons of its own.
      await tester.tap(find.byIcon(LucideIcons.menu));
      await tester.pumpAndSettle();
      expect(find.byKey(_close), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sign-in has the buttons too',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      await _pump(
        tester,
        const Size(1000, 800),
        const LoginPage(),
        {'decorationLayout': ':minimize,close'},
      );
      expect(find.byKey(_close), findsOneWidget);
      expect(find.byKey(const ValueKey('window-maximize')), findsNothing);
    },
  );

  testWidgets(
    'a tiling WM: no buttons anywhere, and the layout still fits',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      await _pump(
        tester,
        const Size(1440, 900),
        const AppShell(),
        {
          'decorationLayout': ':close',
          'env': {'SWAYSOCK': '/run/sway'},
        },
      );
      expect(find.byKey(_close), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
```

Before running, check `LoginPage`'s constructor in `lib/ui/auth/login_page.dart`. If it requires arguments, build it the way `test/login_page_test.dart` does, and change only that line of the test.

- [ ] **Step 2: Run them to verify they fail**

Run: `mise exec -- flutter test test/window_placement_test.dart`
Expected: FAIL. No surface draws `WindowControls` yet, so `findsOneWidget` fails.

- [ ] **Step 3: Install the chrome in `lib/main.dart`**

Add `import 'ui/window/window_chrome.dart';`. Next to the other app-lifetime globals, add:

```dart
/// The window's own controls, in place of the OS title bar. Lives as long
/// as the app, like [themeMode].
final windowChrome = WindowChromeController();
```

In `main()`, before `runApp`:

```dart
  // Before the first frame, so the buttons are there from the start rather
  // than popping in.
  await windowChrome.start();
```

In `MaterialApp(...)` add:

```dart
          builder: (context, child) =>
              WindowChrome(controller: windowChrome, child: child!),
```

- [ ] **Step 4: Scope the shell's columns in `lib/ui/shell/app_shell.dart`**

In the wide `Row` (around line 1112):
- wrap the navigation `SizedBox` in `WindowEdges(leading: true, trailing: false, child: …)`
- change `Expanded(child: main)` to `Expanded(child: WindowEdges(leading: false, trailing: !membersShown, child: main))`
- wrap the member-list `DecoratedBox` in `WindowEdges(leading: false, trailing: true, child: …)`

Hoist the long member-list condition into a local first, so both uses agree:

```dart
        final membersShown =
            members != null &&
            _showMembers &&
            _previewInvite == null &&
            (channel!.kind == ChannelKind.text ||
                channel.kind == ChannelKind.room ||
                // A voice channel that can't be joined yet is
                // the same pane as a room, toggle and all.
                (channel.kind == ChannelKind.voice && !_voiceWorks));
```

Then use `if (membersShown)` in place of the inline condition. When `_fullscreen`, `main` is the whole body with no `WindowEdges`, so it touches both corners, which is right.

In the narrow `Scaffold`:
- wrap both drawers' `child:` in `WindowEdges.none(child: …)`, since they slide over the page that already holds the buttons
- leave `body: main` unwrapped, because it is the whole window

- [ ] **Step 5: Add bands and drag areas**

1. `spaces_rail.dart`. The rail's `Container` child becomes a `Column`:

   ```dart
      child: Column(
        children: [
          // A Mac's buttons, or Linux's when its layout puts them on the
          // left, sit above the loaf mark.
          const WindowBand(),
          Expanded(
            child: SafeArea(
              right: false,
              // …the existing Padding/Column unchanged…
            ),
          ),
        ],
      ),
   ```

   `WindowBand` (Task 2) already fits itself to the 76pt rail.

2. `member_list.dart`. Change `ColoredBox(color: tokens.sidebar, child: SafeArea(...))` to `ColoredBox(color: tokens.sidebar, child: Column(children: [const WindowBand(), Expanded(child: SafeArea(...))]))`.

3. `login_page.dart`. Change the `Scaffold` body from `SafeArea(...)` to `Column(children: [const WindowBand(), Expanded(child: SafeArea(...))])`.

4. `shell_faces.dart` (`_Face`). When `onOpenNavigation == null`, the first `Column` child becomes `const WindowBand()`. When it isn't null, the bar `Container` follows the pattern: `WindowDragArea` around it, and its child becomes `Row(children: [const WindowControls(WindowEdge.leading), TopBarButton(...), const Spacer(), const WindowControls(WindowEdge.trailing)])`. Drop `alignment: Alignment.centerLeft`, because the `Row` now aligns its children.

   The `SafeArea` wraps the whole `Column`. That's fine on desktop, where the safe-area insets are zero.

5. `channel_view.dart` `_ChannelHeader`, `invite_preview.dart` header, `voice_channel_page.dart` header, and `call_view.dart` `CallTopBar`: apply the pattern. In `invite_preview.dart`, also put a `const Spacer()` before the trailing controls, since that `Row` has no `Expanded`.

6. `channel_list.dart` `_Header`: wrap the `Container` in `WindowDragArea`. Add no controls, because the channel list never touches a corner.

7. `image_viewer.dart` `_Bar`: wrap the `DecoratedBox` in `WindowDragArea`. Add `const WindowControls(WindowEdge.leading)` first in the `Row` and `const WindowControls(WindowEdge.trailing)` last, after the close-viewer `IconButton`. The viewer is a full-window route outside every `WindowEdges`, so it gets both corners.

- [ ] **Step 6: Run the placement tests and the whole suite**

Run: `mise exec -- flutter test test/window_placement_test.dart test/window_chrome_test.dart`
Expected: PASS.

Run: `mise exec -- flutter test`
Expected: PASS, all tests. The existing tests have no `WindowChrome`, so every new widget is inert there. If an existing test now fails, the change broke "inert without `WindowChrome`". Fix the widget, not the test.

Run: `mise exec -- flutter analyze`
Expected: No issues.

- [ ] **Step 7: Record the plan's differences in the spec**

In `docs/superpowers/specs/2026-10-06-window-chrome-design.md`:
- In **Native → Linux**, replace the `gtk_window_set_decorated(FALSE)` bullet with: "On a tiling WM the empty titlebar stays: GTK3 already drops its shadows and resize margins for a tiled window, and a floating one keeps its resize edges."
- Replace the `startDrag` bullet with: "`startDrag` → `gtk_window_begin_move_drag` at the pointer's current position, button 1, `gtk_get_current_event_time()`. Flutter starts a drag from a press it still holds, so the WM sees a live button."
- In **Windows**, add `maxHovered` to the state.
- In **The channel**, add `maxHovered: bool` (Windows only) to the state map.
- Under **Where the controls go**, add one line: "Bands are `WindowMetrics.band` = 56pt, the headers' height. Each bar holds its own controls; `WindowEdges` per column decides which bar touches which corner, so each corner draws once."
- Change the test paths to `test/window_state_test.dart`, `test/window_chrome_test.dart` and `test/window_placement_test.dart`.

- [ ] **Step 8: Commit**

```bash
git add lib test/window_placement_test.dart docs/superpowers/specs/2026-10-06-window-chrome-design.md
git commit -m "feat(window): the buttons fold into the columns that touch each corner

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: macOS runner

**Files:**
- Create: `macos/Runner/WindowChromeBridge.swift`
- Modify: `macos/Runner/MainFlutterWindow.swift`
- Modify: `macos/Runner.xcodeproj/project.pbxproj` (four entries, mirroring `UpdaterBridge.swift` at lines 24, 66, 175, 365)

**Interfaces:**
- Consumes: the `loaf/window` contract in Global Constraints. The state map keys are `maximized`, `fullscreen` and `focused`.

- [ ] **Step 1: Write `macos/Runner/WindowChromeBridge.swift`**

```swift
import Cocoa
import FlutterMacOS

/// Hides the system's title bar and buttons, and does what Loaf's own ask
/// for over `loaf/window`. The window stays `.titled`, so it keeps its
/// shadow, rounded corners, resize edges and native fullscreen.
final class WindowChromeBridge: NSObject {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var observers: [NSObjectProtocol] = []

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    channel = FlutterMethodChannel(name: "loaf/window", binaryMessenger: messenger)
    super.init()
    Self.hideTitleBar(of: window)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    let names: [Notification.Name] = [
      NSWindow.didEnterFullScreenNotification,
      NSWindow.didExitFullScreenNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didResizeNotification,
    ]
    for name in names {
      observers.append(
        NotificationCenter.default.addObserver(
          forName: name, object: window, queue: .main
        ) { [weak self] _ in self?.sendState() })
    }
  }

  deinit {
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  private static func hideTitleBar(of window: NSWindow) {
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
      window.standardWindowButton(kind)?.isHidden = true
    }
  }

  private func handle(_ call: FlutterMethodCall, result: FlutterResult) {
    guard let window else {
      result(nil)
      return
    }
    switch call.method {
    case "state":
      result(state(of: window))
    case "minimize":
      window.miniaturize(nil)
      result(nil)
    case "toggleMaximize":
      window.zoom(nil)
      result(nil)
    case "close":
      // Through the close path, so the delegate's quit-after-last-window
      // rule still applies.
      window.performClose(nil)
      result(nil)
    case "startDrag":
      // Called from Flutter's pan start, inside a live mouse drag.
      if let event = window.currentEvent {
        window.performDrag(with: event)
      }
      result(nil)
    case "titlebarDoubleClick":
      doubleClick(window)
      result(nil)
    case "setMaxButtonRect":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func state(of window: NSWindow) -> [String: Any] {
    [
      "maximized": window.isZoomed,
      "fullscreen": window.styleMask.contains(.fullScreen),
      "focused": window.isKeyWindow,
    ]
  }

  private func sendState() {
    guard let window else { return }
    channel.invokeMethod("stateChanged", arguments: state(of: window))
  }

  /// Does what the person set in System Settings › Desktop & Dock for a
  /// title bar double-click: zoom (the default), minimize, or nothing.
  private func doubleClick(_ window: NSWindow) {
    let defaults = UserDefaults.standard
    switch defaults.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize":
      window.miniaturize(nil)
    case "None":
      break
    case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"):
      window.miniaturize(nil)
    default:
      window.zoom(nil)
    }
  }
}
```

- [ ] **Step 2: Wire it in `MainFlutterWindow.swift`**

Add `private var windowChrome: WindowChromeBridge?` next to `updaterBridge`. After the `updaterBridge = …` line, add:

```swift
    windowChrome = WindowChromeBridge(
      window: self, messenger: flutterViewController.engine.binaryMessenger)
```

- [ ] **Step 3: Add the file to the Xcode project**

In `project.pbxproj`, add four lines mirroring `UpdaterBridge.swift`. Use IDs `A1B2C3D4E5F60718293A4C01` (build file) and `A1B2C3D4E5F60718293A4C02` (file ref), after checking with `grep` that neither is already used:
- a `PBXBuildFile` line after line 24
- a `PBXFileReference` line after line 66
- a group child after line 175
- a Sources build phase entry after line 365

- [ ] **Step 4: Build**

Run: `mise exec -- flutter build macos --debug`
Expected: build succeeds.

- [ ] **Step 5: Manual check (controller does this, not a subagent)**

1. `pgrep -x "Loaf Chat"`. If anything prints, stop and ask Chris to quit the installed app.
2. Run the debug app and take screenshots, in dark and in light (Ctrl+T), at wide and at narrow (under 900pt) widths.
3. Check that:
   - The dots sit in the rail, there is no system title bar, and the shadow and corners are intact.
   - Hovering the dots colours them.
   - Close, minimize and zoom each work.
   - Dragging the channel header moves the window, including snapping to the screen edge.
   - Double-clicking the header zooms.
   - ⌃⌘F enters fullscreen, the dots vanish, and they come back on exit.
   - **Review Focus 5:** the members toggle and call buttons in the channel header (inside the top 28pt) respond to one click.
4. If clicks in the top 28pt move the window instead of reaching Flutter, add `window.isMovable = false` in `hideTitleBar`. Then confirm that `performDrag(with:)` still moves the window, and check again.
5. If `performClose` beeps instead of closing, use `window.close()` instead. `AppDelegate` already quits after the last window.

- [ ] **Step 6: Commit**

```bash
git add macos
git commit -m "feat(window): macOS hides its title bar and answers Loaf's buttons

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Linux runner

**Files:**
- Create: `linux/runner/window_chrome.h`, `linux/runner/window_chrome.cc`
- Modify: `linux/runner/my_application.cc` (the header-bar block and the plugin registration)
- Modify: `linux/runner/CMakeLists.txt` (add `"window_chrome.cc"` to `add_executable`)

**Interfaces:**
- Consumes: the `loaf/window` contract. The state map keys are `maximized`, `fullscreen`, `focused`, `tiled`, `wmName`, `env` and `decorationLayout`.

- [ ] **Step 1: Write `linux/runner/window_chrome.h`**

```cpp
#ifndef RUNNER_WINDOW_CHROME_H_
#define RUNNER_WINDOW_CHROME_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Hides GTK's title bar, keeping its client-side shadows and resize edges,
// and answers Loaf's own window buttons over the `loaf/window` channel.
// Call before the window is shown. Lives as long as |window|.
void window_chrome_attach(GtkWindow* window, FlView* view);

#endif  // RUNNER_WINDOW_CHROME_H_
```

- [ ] **Step 2: Write `linux/runner/window_chrome.cc`**

```cpp
#include "window_chrome.h"

#include <cstring>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

namespace {

struct WindowChrome {
  GtkWindow* window;
  FlMethodChannel* channel;
  GdkWindowState state;
};

// Raw facts for Dart's tiling-WM rules; native decides nothing.
constexpr const char* kTilingEnv[] = {
    "XDG_CURRENT_DESKTOP", "SWAYSOCK", "HYPRLAND_INSTANCE_SIGNATURE",
    "NIRI_SOCKET", "I3SOCK",
};

constexpr int kAllTiled =
    GDK_WINDOW_STATE_TOP_TILED | GDK_WINDOW_STATE_RIGHT_TILED |
    GDK_WINDOW_STATE_BOTTOM_TILED | GDK_WINDOW_STATE_LEFT_TILED;

FlValue* state_value(WindowChrome* self) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(
      map, "maximized",
      fl_value_new_bool(self->state & GDK_WINDOW_STATE_MAXIMIZED));
  fl_value_set_string_take(
      map, "fullscreen",
      fl_value_new_bool(self->state & GDK_WINDOW_STATE_FULLSCREEN));
  fl_value_set_string_take(map, "focused",
                           fl_value_new_bool(gtk_window_is_active(self->window)));
  fl_value_set_string_take(
      map, "tiled", fl_value_new_bool((self->state & kAllTiled) == kAllTiled));

  FlValue* wm_name = fl_value_new_null();
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(self->window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* name = gdk_x11_screen_get_window_manager_name(screen);
    if (name != nullptr) {
      fl_value_unref(wm_name);
      wm_name = fl_value_new_string(name);
    }
  }
#endif
  fl_value_set_string_take(map, "wmName", wm_name);

  FlValue* env = fl_value_new_map();
  for (const char* name : kTilingEnv) {
    const gchar* value = g_getenv(name);
    if (value != nullptr) {
      fl_value_set_string_take(env, name, fl_value_new_string(value));
    }
  }
  fl_value_set_string_take(map, "env", env);

  g_autofree gchar* layout = nullptr;
  g_object_get(gtk_settings_get_default(), "gtk-decoration-layout", &layout,
               nullptr);
  if (layout != nullptr) {
    fl_value_set_string_take(map, "decorationLayout",
                             fl_value_new_string(layout));
  }
  return map;
}

void send_state(WindowChrome* self) {
  g_autoptr(FlValue) state = state_value(self);
  fl_method_channel_invoke_method(self->channel, "stateChanged", state,
                                  nullptr, nullptr, nullptr);
}

void toggle_maximize(WindowChrome* self) {
  if (self->state & GDK_WINDOW_STATE_MAXIMIZED) {
    gtk_window_unmaximize(self->window);
  } else {
    gtk_window_maximize(self->window);
  }
}

// Flutter starts a drag from a press it is still holding, so the window
// manager sees a live button and takes over the move, snapping included.
// On Wayland GDK uses the seat's grab serial and ignores the coordinates.
void start_drag(WindowChrome* self) {
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(self->window));
  if (gdk_window == nullptr) return;
  GdkSeat* seat = gdk_display_get_default_seat(gdk_window_get_display(gdk_window));
  GdkDevice* pointer = gdk_seat_get_pointer(seat);
  gint x = 0, y = 0;
  gdk_device_get_position(pointer, nullptr, &x, &y);
  gtk_window_begin_move_drag(self->window, GDK_BUTTON_PRIMARY, x, y,
                             gtk_get_current_event_time());
}

void method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                    gpointer user_data) {
  auto* self = static_cast<WindowChrome*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "state") == 0) {
    g_autoptr(FlValue) state = state_value(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(state));
  } else {
    if (strcmp(method, "minimize") == 0) {
      gtk_window_iconify(self->window);
    } else if (strcmp(method, "toggleMaximize") == 0 ||
               strcmp(method, "titlebarDoubleClick") == 0) {
      toggle_maximize(self);
    } else if (strcmp(method, "close") == 0) {
      gtk_window_close(self->window);
    } else if (strcmp(method, "startDrag") == 0) {
      start_drag(self);
    } else if (strcmp(method, "setMaxButtonRect") != 0) {
      fl_method_call_respond_not_implemented(call, nullptr);
      return;
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }
  fl_method_call_respond(call, response, nullptr);
}

gboolean window_state_cb(GtkWidget*, GdkEventWindowState* event,
                         gpointer user_data) {
  auto* self = static_cast<WindowChrome*>(user_data);
  self->state = event->new_window_state;
  send_state(self);
  return FALSE;
}

void notify_cb(GObject*, GParamSpec*, gpointer user_data) {
  send_state(static_cast<WindowChrome*>(user_data));
}

void destroy_cb(GtkWidget*, gpointer user_data) {
  auto* self = static_cast<WindowChrome*>(user_data);
  g_signal_handlers_disconnect_by_data(gtk_settings_get_default(), self);
  fl_method_channel_set_method_call_handler(self->channel, nullptr, nullptr,
                                            nullptr);
  g_object_unref(self->channel);
  delete self;
}

}  // namespace

void window_chrome_attach(GtkWindow* window, FlView* view) {
  // A titlebar widget that is never shown keeps GTK's client-side
  // decorations (shadow, resize edges) and draws no bar. A shown one would
  // take the theme's title bar height.
  gtk_window_set_titlebar(window, gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0));

  auto* self = new WindowChrome{window, nullptr, GdkWindowState(0)};
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "loaf/window",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_call_cb,
                                            self, nullptr);
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_state_cb),
                   self);
  g_signal_connect(window, "notify::is-active", G_CALLBACK(notify_cb), self);
  g_signal_connect(gtk_settings_get_default(), "notify::gtk-decoration-layout",
                   G_CALLBACK(notify_cb), self);
  g_signal_connect(window, "destroy", G_CALLBACK(destroy_cb), self);
}
```

- [ ] **Step 3: Use it in `my_application.cc`**
- Delete the whole `use_header_bar` block (from the "Use a header bar…" comment through the closing `}` of the `else`) and the now-unused `#ifdef GDK_WINDOWING_X11 #include <gdk/gdkx.h>` at the top.
- In its place, keep the title for the WM and the taskbar: `gtk_window_set_title(window, "Loaf Chat");`.
- Add `#include "window_chrome.h"`.
- After `fl_register_plugins(FL_PLUGIN_REGISTRY(view));`, add:

```cpp
  // Loaf draws its own title-bar buttons; GTK's bar goes.
  window_chrome_attach(window, view);
```

- [ ] **Step 4: Add the source to CMake**

In `linux/runner/CMakeLists.txt`, add `"window_chrome.cc"` after `"my_application.cc"` in `add_executable`.

- [ ] **Step 5: Verify it compiles**

There's no Linux box here. CI builds Linux on push. Locally, run the Dart suite to make sure nothing regressed:

Run: `mise exec -- flutter test`
Expected: PASS.

Review the C++ by hand against the GTK3 / flutter_linux headers: `$(mise where flutter)/bin/cache/artifacts/engine/linux-x64/flutter_linux/` if present, otherwise the engine's `shell/platform/linux/public/flutter_linux/*.h`. Check that every `fl_*` call matches its signature. In particular, check `fl_method_success_response_new` (takes `FlValue*` and refs it) and `fl_value_set_string_take` (takes ownership).

- [ ] **Step 6: Commit**

```bash
git add linux/runner
git commit -m "feat(window): GTK keeps its shadows and edges, loses its bar

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Windows runner

**Files:**
- Create: `windows/runner/window_chrome.h`, `windows/runner/window_chrome.cpp`
- Modify: `windows/runner/flutter_window.h`, `windows/runner/flutter_window.cpp`
- Modify: `windows/runner/CMakeLists.txt` (source plus `comctl32.lib`)

**Interfaces:**
- Consumes: the `loaf/window` contract. The state map keys are `maximized`, `focused` and `maxHovered`. `setMaxButtonRect` takes `{x, y, w, h}` in logical pixels.

- [ ] **Step 1: Write `windows/runner/window_chrome.h`**

```cpp
#ifndef RUNNER_WINDOW_CHROME_H_
#define RUNNER_WINDOW_CHROME_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>

// Removes the caption, keeps the resize frame and Aero Snap, and answers
// Loaf's own window buttons over `loaf/window`.
class WindowChrome {
 public:
  WindowChrome(HWND window, flutter::BinaryMessenger* messenger);
  ~WindowChrome();

  // Lets the Flutter view pass the top resize edge and the maximize button
  // through to the frame, which owns them.
  void AttachChild(HWND child);

  // Frame messages for the top-level window; a value when handled.
  std::optional<LRESULT> HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  static LRESULT CALLBACK ChildProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam, UINT_PTR id,
                                    DWORD_PTR data);

  // Where |screen| falls: HTTOP*, HTMAXBUTTON, or HTCLIENT.
  LRESULT HitTest(POINT screen) const;
  int FrameX() const;
  int FrameY() const;
  flutter::EncodableValue State() const;
  void SendState();
  void SetMaxHovered(bool hovered);

  HWND window_;
  HWND child_ = nullptr;
  RECT max_button_{};  // physical pixels, client coordinates
  bool max_hovered_ = false;
  bool max_pressed_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_WINDOW_CHROME_H_
```

- [ ] **Step 2: Write `windows/runner/window_chrome.cpp`**

```cpp
#include "window_chrome.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <string>

namespace {

constexpr UINT_PTR kChildSubclassId = 1;

double ArgDouble(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return 0;
  if (auto* d = std::get_if<double>(&it->second)) return *d;
  if (auto* i = std::get_if<int32_t>(&it->second)) return *i;
  return 0;
}

}  // namespace

WindowChrome::WindowChrome(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "loaf/window", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const std::string& method = call.method_name();
    if (method == "state") {
      result->Success(State());
      return;
    }
    if (method == "minimize") {
      ShowWindow(window_, SW_MINIMIZE);
    } else if (method == "toggleMaximize" || method == "titlebarDoubleClick") {
      ShowWindow(window_, IsZoomed(window_) ? SW_RESTORE : SW_MAXIMIZE);
    } else if (method == "close") {
      PostMessage(window_, WM_CLOSE, 0, 0);
    } else if (method == "startDrag") {
      // The system's own move loop, so Aero Snap and snap layouts work.
      // Posted, not sent, so this reply isn't held up for the whole move.
      ReleaseCapture();
      PostMessage(window_, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    } else if (method == "setMaxButtonRect") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args != nullptr) {
        const double scale = GetDpiForWindow(window_) / 96.0;
        max_button_ = RECT{
            static_cast<LONG>(ArgDouble(*args, "x") * scale),
            static_cast<LONG>(ArgDouble(*args, "y") * scale),
            static_cast<LONG>((ArgDouble(*args, "x") + ArgDouble(*args, "w")) *
                              scale),
            static_cast<LONG>((ArgDouble(*args, "y") + ArgDouble(*args, "h")) *
                              scale)};
      }
    } else {
      result->NotImplemented();
      return;
    }
    result->Success();
  });

  // A one-pixel top margin keeps DWM's shadow on a window with no caption.
  const MARGINS margins{0, 0, 1, 0};
  DwmExtendFrameIntoClientArea(window_, &margins);
  // Recalculates the frame now that WM_NCCALCSIZE is ours.
  SetWindowPos(window_, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);
}

WindowChrome::~WindowChrome() {
  if (child_ != nullptr) {
    RemoveWindowSubclass(child_, ChildProc, kChildSubclassId);
  }
  channel_->SetMethodCallHandler(nullptr);
}

void WindowChrome::AttachChild(HWND child) {
  child_ = child;
  SetWindowSubclass(child, ChildProc, kChildSubclassId,
                    reinterpret_cast<DWORD_PTR>(this));
}

int WindowChrome::FrameX() const {
  const UINT dpi = GetDpiForWindow(window_);
  return GetSystemMetricsForDpi(SM_CXFRAME, dpi) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

int WindowChrome::FrameY() const {
  const UINT dpi = GetDpiForWindow(window_);
  return GetSystemMetricsForDpi(SM_CYFRAME, dpi) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

LRESULT WindowChrome::HitTest(POINT screen) const {
  POINT p = screen;
  ScreenToClient(window_, &p);
  RECT client;
  GetClientRect(window_, &client);
  // The caption is gone, so the top resize edge lies inside the client
  // area and has to be claimed here.
  if (!IsZoomed(window_) && p.y >= 0 && p.y < FrameY()) {
    if (p.x < FrameX()) return HTTOPLEFT;
    if (p.x >= client.right - FrameX()) return HTTOPRIGHT;
    return HTTOP;
  }
  if (PtInRect(&max_button_, p)) return HTMAXBUTTON;
  return HTCLIENT;
}

LRESULT CALLBACK WindowChrome::ChildProc(HWND hwnd, UINT message,
                                         WPARAM wparam, LPARAM lparam,
                                         UINT_PTR, DWORD_PTR data) {
  if (message == WM_NCHITTEST) {
    auto* self = reinterpret_cast<WindowChrome*>(data);
    const POINT screen{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    if (self->HitTest(screen) != HTCLIENT) return HTTRANSPARENT;
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

std::optional<LRESULT> WindowChrome::HandleMessage(HWND hwnd, UINT message,
                                                   WPARAM wparam,
                                                   LPARAM lparam) {
  switch (message) {
    case WM_NCCALCSIZE: {
      if (!wparam) return std::nullopt;
      auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
      RECT& r = params->rgrc[0];
      // Sides and bottom keep the resize frame; the caption at the top goes.
      r.left += FrameX();
      r.right -= FrameX();
      r.bottom -= FrameY();
      // A maximized window hangs its frame off the screen; keep the top of
      // the client area on it.
      if (IsZoomed(hwnd)) r.top += FrameY();
      return 0;
    }
    case WM_NCHITTEST: {
      const POINT screen{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      const LRESULT hit = HitTest(screen);
      if (hit != HTCLIENT) return hit;
      return std::nullopt;  // sides and bottom: the default frame
    }
    // Over the maximize button the frame gets the mouse, which is what
    // makes Windows 11 offer snap layouts. Its clicks and hover are
    // forwarded so the button still behaves and looks like Loaf's.
    case WM_NCMOUSEMOVE: {
      SetMaxHovered(wparam == HTMAXBUTTON);
      if (wparam == HTMAXBUTTON) {
        TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE | TME_NONCLIENT, hwnd,
                              0};
        TrackMouseEvent(&track);
      }
      return std::nullopt;
    }
    case WM_NCMOUSELEAVE:
      SetMaxHovered(false);
      max_pressed_ = false;
      return std::nullopt;
    case WM_NCLBUTTONDOWN:
      if (wparam == HTMAXBUTTON) {
        max_pressed_ = true;
        return 0;  // no classic button press
      }
      return std::nullopt;
    case WM_NCLBUTTONUP:
      if (wparam == HTMAXBUTTON) {
        if (max_pressed_) {
          ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
        }
        max_pressed_ = false;
        return 0;
      }
      return std::nullopt;
    case WM_SIZE:
    case WM_ACTIVATE:
      SendState();
      return std::nullopt;
  }
  return std::nullopt;
}

flutter::EncodableValue WindowChrome::State() const {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("maximized"),
       flutter::EncodableValue(IsZoomed(window_) != 0)},
      {flutter::EncodableValue("focused"),
       flutter::EncodableValue(GetForegroundWindow() == window_)},
      {flutter::EncodableValue("maxHovered"),
       flutter::EncodableValue(max_hovered_)},
  });
}

void WindowChrome::SendState() {
  channel_->InvokeMethod("stateChanged",
                         std::make_unique<flutter::EncodableValue>(State()));
}

void WindowChrome::SetMaxHovered(bool hovered) {
  if (hovered == max_hovered_) return;
  max_hovered_ = hovered;
  SendState();
}
```

`GetDpiForWindow` and `GetSystemMetricsForDpi` need Windows 10 1607 or later, which Flutter's own floor already exceeds. If the SDK headers hide them behind `WINVER`, use `FlutterDesktopGetDpiForHWND(window_)` from `flutter_windows.h` for the DPI.

Note that `WM_ACTIVATE`'s "focused" is read after the message has been delivered. Use `LOWORD(wparam) != WA_INACTIVE` if `GetForegroundWindow` still lags at that point. Prefer the `wparam` form if in doubt: store a `focused_` bool set from `WM_ACTIVATE` and report that.

- [ ] **Step 3: Wire it into `FlutterWindow`**

In `flutter_window.h`, add `#include "window_chrome.h"` and a member `std::unique_ptr<WindowChrome> chrome_;`.

In `flutter_window.cpp` `OnCreate()`, after `SetChildContent(...)`, add:

```cpp
  // Loaf draws its own title-bar buttons; the caption goes.
  chrome_ = std::make_unique<WindowChrome>(
      GetHandle(), flutter_controller_->engine()->messenger());
  chrome_->AttachChild(flutter_controller_->view()->GetNativeWindow());
```

In `OnDestroy()`, add `chrome_ = nullptr;` before `flutter_controller_ = nullptr;`.

In `MessageHandler`, right after the Flutter `HandleTopLevelWindowProc` block, add:

```cpp
  if (chrome_) {
    if (std::optional<LRESULT> result =
            chrome_->HandleMessage(hwnd, message, wparam, lparam)) {
      return *result;
    }
  }
```

- [ ] **Step 4: CMake**

In `windows/runner/CMakeLists.txt`:
- add `"window_chrome.cpp"` after `"win32_window.cpp"`
- add `target_link_libraries(${BINARY_NAME} PRIVATE "comctl32.lib")` next to the existing `dwmapi.lib` line

- [ ] **Step 5: Verify**

There's no Windows toolchain here, and Windows CI is off. Review every Win32 call against its documented signature, then run `mise exec -- flutter test` to confirm the Dart side is unaffected. The report must say plainly: **"Windows runner not compiled or run."**

- [ ] **Step 6: Commit**

```bash
git add windows/runner
git commit -m "feat(window): Windows drops its caption, keeps snap layouts

Unverified: not compiled or run here; Windows CI is off.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
