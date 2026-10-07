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
  int get hashCode =>
      Object.hash(Object.hashAll(leading), Object.hashAll(trailing));

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
  'sway',
  'hyprland',
  'niri',
  'river',
  'i3',
  'bspwm',
  'qtile',
  'awesome',
  'dwm',
  'xmonad',
  'herbstluftwm',
};

// LG3D is what dwm and xmonad commonly advertise, to get Java apps drawing.
const _tilingWmNames = {
  'i3',
  'bspwm',
  'awesome',
  'dwm',
  'xmonad',
  'herbstluftwm',
  'qtile',
  'lg3d',
  'spectrwm',
  'leftwm',
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
