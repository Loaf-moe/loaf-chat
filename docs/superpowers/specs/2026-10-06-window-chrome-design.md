# Window chrome — design

The OS title bar and its minimize / maximize / close buttons go, on every
desktop platform. Loaf draws its own controls in its own palette, folded
into the columns it already has, so no height is lost to a bar. The
*behaviour* stays native: real window moves, snapping, resize edges,
shadows, the user's own double-click setting. On a Linux tiling window
manager there are no window controls at all.

Mobile is untouched. Every widget here is inert unless [isDesktop].

## Decisions (2026-10-06)

| Question | Answer |
|---|---|
| Where controls live | Folded into the columns, not a separate strip. Header backgrounds are the drag area |
| Look | Platform shape, Loaf skin. macOS: three dots, top-left. Linux and Windows: Lucide pills, top-right (Linux: wherever `gtk-decoration-layout` says) |
| Tiling WM | Controls hidden whenever the WM is a tiling one, floating windows included. Known WMs are detected at launch; an unknown WM counts while GDK reports the window tiled on all four edges |
| Windows | In scope, but untestable here: no Windows box, Windows CI is off. It ships to the same design and is flagged as unverified |

## Native: frames go, behaviour stays

### macOS — `macos/Runner/MainFlutterWindow.swift`, new `WindowChromeBridge.swift`

- `styleMask.insert(.fullSizeContentView)`, `titlebarAppearsTransparent =
  true`, `titleVisibility = .hidden`, and the three
  `standardWindowButton(_:)` set `isHidden = true`. The window stays
  `.titled`, so it keeps the shadow, rounded corners, resize edges and
  native fullscreen.
- `minimize` → `miniaturize(nil)`. `toggleMaximize` → `zoom(nil)`. `close`
  → `performClose(nil)`, so the app delegate's terminate-after-last-window
  rule still applies.
- `startDrag` → `performDrag(with: currentEvent)`. Flutter calls it from the
  pan-start of a live mouse drag, so `currentEvent` is that drag.
- `titlebarDoubleClick` reads `AppleActionOnDoubleClick` from the global
  defaults: `Minimize` miniaturizes, `None` does nothing, and anything else
  zooms (the macOS default).
- Fullscreen: Loaf's dots hide, as macOS hides its own there. Esc and the
  green-button menu are not reproduced. Fullscreen is still reachable from
  the View menu and ⌃⌘F.
- State comes from `NSWindow` notifications: did/will enter/exit full
  screen, become/resign key, and did resize (for zoomed).

### Linux — `linux/runner/my_application.cc`, new `window_chrome.cc/.h`

- The `GtkHeaderBar` branch and the X11 plain-title branch are deleted. The
  titlebar becomes an empty `GtkBox` of height 0 via
  `gtk_window_set_titlebar`. With that set, GTK keeps client-side shadows
  and resize edges and draws no bar.
- On a tiling WM the empty titlebar stays: GTK3 already drops its shadows
  and resize margins for a tiled window, and a floating one keeps its resize
  edges.
- `minimize` → `gtk_window_iconify`. `toggleMaximize` → `gtk_window_maximize`
  or `gtk_window_unmaximize`. `close` → `gtk_window_close`.
- `startDrag` → `gtk_window_begin_move_drag` at the pointer's current
  position, button 1, `gtk_get_current_event_time()`. Flutter starts a drag
  from a press it still holds, so the WM sees a live button.
- `titlebarDoubleClick` → toggle maximize.
- State comes from `window-state-event`: `GDK_WINDOW_STATE_MAXIMIZED`,
  `FULLSCREEN`, `FOCUSED`, and the four `*_TILED` edges. It also comes from
  `notify::gtk-decoration-layout` on `GtkSettings`.
- The raw facts for tiling detection go to Dart; native decides nothing:
  - the X11 `_NET_WM` name (`gdk_x11_screen_get_window_manager_name`), or
    null on Wayland
  - the environment variables `XDG_CURRENT_DESKTOP`, `SWAYSOCK`,
    `HYPRLAND_INSTANCE_SIGNATURE`, `NIRI_SOCKET` and `I3SOCK`
  - whether all four edges are tiled

### Windows — `windows/runner/win32_window.cpp`, new `window_chrome.cpp/.h`

- `WM_NCCALCSIZE` returns the client area as the whole window, minus the
  resize borders (`SM_CXFRAME` + `SM_CXPADDEDBORDER`), and minus nothing
  when maximized beyond keeping off the taskbar.
  `DwmExtendFrameIntoClientArea` with a 1px top margin keeps the shadow.
- `WM_NCHITTEST` on the top-level window returns the resize edges, and
  `HTMAXBUTTON` inside the maximize button's rect, which Dart reports with
  `setMaxButtonRect`. That is what makes Windows 11 show its snap-layout
  flyout. The Flutter child window is subclassed to return
  `HTTRANSPARENT` over that rect and over the resize edges, so the parent
  gets the hit test.
- `startDrag` → `ReleaseCapture()` then `SendMessage(WM_NCLBUTTONDOWN,
  HTCAPTION)`, which gives a real move with Aero Snap.
- `minimize` / `toggleMaximize` / `close` → `ShowWindow(SW_MINIMIZE)`,
  `SW_MAXIMIZE`/`SW_RESTORE`, `PostMessage(WM_CLOSE)`.
  `titlebarDoubleClick` → toggle maximize.
- State comes from `WM_SIZE` (maximized) and `WM_ACTIVATE` (focused). It
  also carries `maxHovered`: over the maximize button, mouse events go to the
  frame and not to Flutter, so the runner says when to show hover.

## The channel — `loaf/window`

`MethodChannel('loaf/window')`, one per platform runner.

Dart → native: `minimize`, `toggleMaximize`, `close`, `startDrag`,
`titlebarDoubleClick`, `setMaxButtonRect {x, y, w, h}` (Windows only;
logical pixels; others ignore it), and `state` (returns the current state).

Native → Dart: `stateChanged` with the same map `state` returns:

```
{ maximized: bool, fullscreen: bool, focused: bool,
  maxHovered: bool,  // Windows only
  // Linux only; absent elsewhere
  wmName: String?, env: {String: String}, tiled: bool,
  decorationLayout: String }
```

## Dart — `lib/ui/window/`

### `window_state.dart`: pure, unit-tested

- `enum WindowButton { minimize, maximize, close }`.
- `class ButtonLayout { List<WindowButton> leading, trailing; }`.
  `ButtonLayout.parseGtk(String)` reads `gtk-decoration-layout`: left and
  right of `:`, comma-separated, unknown names (`icon`, `appmenu`, `menu`)
  dropped. Examples:
  - `:close` puts close on the right
  - `close,minimize,maximize:` puts all three on the left
  - an empty string gives no buttons
- `bool isTilingWm({String? wmName, Map<String, String> env, bool tiled})`:
  - true when `tiled` is true
  - true when any of `SWAYSOCK`, `HYPRLAND_INSTANCE_SIGNATURE`,
    `NIRI_SOCKET` or `I3SOCK` is set
  - true when `XDG_CURRENT_DESKTOP`, split on `:` and compared without
    case, contains `sway`, `hyprland`, `niri`, `river`, `i3`, `bspwm`,
    `qtile`, `awesome`, `dwm`, `xmonad` or `herbstluftwm`
  - true when `wmName`, compared without case, is one of `i3`, `bspwm`,
    `awesome`, `dwm`, `xmonad`, `herbstluftwm`, `qtile`, `LG3D` (what dwm
    and xmonad often advertise), `spectrwm` or `leftwm`
- `class WindowState { maximized, fullscreen, focused, ButtonLayout layout }`,
  built by `WindowState.fromPlatform(TargetPlatform, Map)`:
  - macOS: the layout is all three leading. If `fullscreen`, the layout is
    empty.
  - Windows: the layout is all three trailing.
  - Linux: the layout is `parseGtk(decorationLayout)`. If `isTilingWm(...)`,
    the layout is empty.

### `window_chrome.dart`

- `WindowChromeController extends ChangeNotifier` owns the channel, holds
  the `WindowState`, and forwards the actions. It takes a `MethodChannel`
  so tests can use a fake one. On mobile, or when the channel is missing,
  the state is "no buttons" and every action does nothing.
- `WindowChrome extends InheritedNotifier<WindowChromeController>` is
  installed in `MaterialApp.builder` in `main.dart`, so it covers sign-in,
  the shell and every route. It provides:
  - `leadingInset` / `trailingInset`: the width the controls take on each
    side, 0 when that side has none
  - `bandHeight`: the controls' height, 0 with no buttons
- `WindowControls({required WindowEdge edge})` draws one side's buttons
  (`edge` is leading or trailing). It draws nothing when that side is empty.
- `WindowDragArea({required Widget child})`:
  - a `GestureDetector` with `onPanStart` → `startDrag` and
    `onDoubleTap` → `titlebarDoubleClick`, using `HitTestBehavior.translucent`
    so buttons inside still take their own taps
  - not a drag area on mobile

### Look

**macOS dots**:
- 12px circles, 8px apart, centred in a 28px-tall strip, with 12px leading
  padding.
- At rest: `textMuted` at 55%.
- Hovering the group: close `accent`, minimize `warning`, zoom `success`,
  each with a 7px Lucide glyph (`x`, `minus`, `plus`) in `textOnAccent`.
- Unfocused: all three at `border`.

**Pills** (Linux, Windows):
- 32×28 `InkWell`s with `LoafRadius.md` and 16px Lucide icons: `minus`,
  `square` (or `copy` when maximized, as Windows shows "restore"), and `x`,
  in `textMuted`.
- Hover: minimize and maximize fill `card`; close fills `accent` with a
  `textOnAccent` icon.
- Unfocused: icons at 50%.
- `LoafMotion.fast` fades, no press scale, since these are window chrome
  and not actions.

### Where the controls go

Bands are `WindowMetrics.band` = 56pt, the headers' height. Each bar holds
its own controls; `WindowEdges` per column decides which bar touches which
corner, so each corner draws once.

| Face | macOS (leading) | Linux / Windows (trailing, or leading per layout) |
|---|---|---|
| Wide shell | A `bandHeight` strip at the top of the `SpacesRail`, above the loaf mark, as a drag area | Inside the rightmost column. On the channel header, the controls sit at its end, past the members toggle, and the header is the drag area. When the member list is open, its top gets a `bandHeight` drag band holding the controls |
| Narrow shell | Before the hamburger in the channel header / `_Face` bar | At the end of the channel header / `_Face` bar |
| Sign-in, `_Face` without a bar | A `WindowBand` (draggable 56pt band) at the top, outside any `SafeArea` | Same band, controls in the trailing corner |
| Call view, call fullscreen | The call bar's own `WindowControls` (the bar is the drag area) | Same, in the trailing corner |

The channel list's space header is a drag area too. Each column that touches
a top corner reads `WindowChrome.of(context)` for its inset, so no control
ever sits over content.

When Linux's layout puts buttons on the left, the leading slot is used.
That is the macOS slot: the rail strip on wide, before the hamburger on
narrow.

## Testing

- **Unit** (`test/window_state_test.dart`): `parseGtk` (the
  GNOME default `appmenu:close`, buttons on the left, empty, unknown
  names); `isTilingWm` (each env var, `XDG_CURRENT_DESKTOP=sway:wlroots`,
  each WM name, GNOME, KDE and an empty env being false, `tiled: true`
  being true); `fromPlatform` (macOS fullscreen empty, Linux tiling empty).
- **Widget** (`test/window_chrome_test.dart`), with a fake
  `MethodChannel`:
  - tapping each button sends its method
  - a pan on `WindowDragArea` sends `startDrag`, and a double tap sends
    `titlebarDoubleClick`
  - a button inside a drag area takes its own tap without starting a drag
  - `stateChanged` to maximized swaps the maximize icon
  - an empty layout draws nothing and gives zero insets
  - on `TargetPlatform.iOS` nothing is drawn
- **Placement** (`test/window_placement_test.dart`): each corner shows its
  buttons exactly once in every shell layout (wide with and without
  members, narrow, call fullscreen, sign-in, Linux left-hand layout), and
  none on a tiling WM.
- **By hand, macOS:** a debug build. Check `pgrep -x "Loaf Chat"` first;
  never run both. Screenshot dark and light, wide and narrow, check drag,
  double-click and fullscreen.
- **Linux / Windows:** CI builds them. Hand checks on GNOME, KDE and sway
  are Chris's. Windows is unverified until someone runs it.

## Known limitations

- Modal dialogs put a barrier over the whole window, Loaf's controls and
  drag bars included, so while one is open the window cannot be moved,
  minimized or closed from the chrome.
- Keyboard close still works: ⌘W and ⌘Q on macOS, Alt+F4 on Windows and
  Linux.
- A root overlay above the navigator would fix it, but it reverses the
  "fold into columns" decision, so the choice is left to Chris.
