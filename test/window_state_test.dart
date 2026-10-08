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

    test('Linux: a maximized window flagged tiled keeps its buttons', () {
      expect(
        WindowState.fromPlatform(TargetPlatform.linux, const {
          'maximized': true,
          'tiled': true,
          'decorationLayout': ':close',
          'env': {'XDG_CURRENT_DESKTOP': 'GNOME'},
        }).layout,
        const ButtonLayout(trailing: [_close]),
      );
    });

    test('Linux: tiled and not maximized has no buttons', () {
      expect(
        WindowState.fromPlatform(TargetPlatform.linux, const {
          'tiled': true,
          'decorationLayout': ':close',
          'env': {'XDG_CURRENT_DESKTOP': 'GNOME'},
        }).layout.isEmpty,
        isTrue,
      );
    });

    test('fullscreen has no buttons on Linux or Windows', () {
      for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
        expect(
          WindowState.fromPlatform(platform, const {
            'fullscreen': true,
            'decorationLayout': ':close',
          }).layout.isEmpty,
          isTrue,
          reason: '$platform',
        );
      }
    });

    test('wrong-typed values from the runner do not throw', () {
      final s = WindowState.fromPlatform(TargetPlatform.linux, const {
        'wmName': 3,
        'env': 'x',
        'decorationLayout': true,
      });
      // Read as absent: GTK's own default layout.
      expect(s.layout, const ButtonLayout(trailing: [_min, _max, _close]));
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
