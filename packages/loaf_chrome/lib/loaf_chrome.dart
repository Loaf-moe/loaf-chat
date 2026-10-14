/// Windows window chrome: Dart over `dart:ffi` into the Rust crate `rust/`,
/// which `hook/build.dart` builds as a DLL. The window loses its frame and
/// Loaf draws its own title-bar buttons; resizing, snapping and the shadow
/// stay Windows' own. Nothing here throws on a missing DLL until
/// [FramelessWindow] is made, so importing it is safe anywhere.
///
/// Every call must come from the platform thread, which owns the window.
/// Flutter on Windows runs the UI isolate there by default; elsewhere
/// [FramelessWindow] finds no window and throws.
library;

import 'dart:ffi';

const _asset = 'package:loaf_chrome/loaf_chrome_win.dart';

/// Called by Rust with the state bits; `NativeCallable.listener` posts it to
/// the isolate.
typedef _StateC = Void Function(Uint32 state);

@Native<Int32 Function(Pointer<NativeFunction<_StateC>>)>(
  symbol: 'loaf_chrome_install',
  assetId: _asset,
)
external int _install(Pointer<NativeFunction<_StateC>> report);

@Native<Void Function()>(symbol: 'loaf_chrome_uninstall', assetId: _asset)
external void _uninstall();

@Native<Int32 Function()>(symbol: 'loaf_chrome_state', assetId: _asset)
external int _state();

@Native<Int32 Function()>(symbol: 'loaf_chrome_minimize', assetId: _asset)
external int _minimize();

@Native<Int32 Function()>(
  symbol: 'loaf_chrome_toggle_maximize',
  assetId: _asset,
)
external int _toggleMaximize();

@Native<Int32 Function()>(symbol: 'loaf_chrome_close', assetId: _asset)
external int _close();

@Native<Int32 Function()>(symbol: 'loaf_chrome_start_drag', assetId: _asset)
external int _startDrag();

@Native<Int32 Function(Double, Double, Double, Double)>(
  symbol: 'loaf_chrome_set_max_button',
  assetId: _asset,
)
external int _setMaxButton(double x, double y, double w, double h);

/// What the window is doing, as the DLL's state bits say.
class ChromeState {
  const ChromeState.fromBits(int bits)
    : maximized = bits & 1 != 0,
      focused = bits & 2 != 0,
      maxHovered = bits & 4 != 0;

  final bool maximized;
  final bool focused;

  /// The pointer is over the maximize button. Windows routes that spot to
  /// the frame so it can offer snap layouts, so Flutter never sees the
  /// hover.
  final bool maxHovered;
}

/// The runner's window, frameless while this lives.
class FramelessWindow {
  /// Takes the window's frame away and calls [onChange] whenever its state
  /// changes. Throws [StateError] with the DLL's status if it can't (no
  /// runner window on this thread), and whatever `dart:ffi` throws if the
  /// DLL isn't there (any OS but Windows). Either way the window keeps its
  /// own frame.
  FramelessWindow(void Function(ChromeState) onChange) {
    _report = NativeCallable<_StateC>.listener(
      (int bits) => onChange(ChromeState.fromBits(bits)),
    );
    try {
      final status = _install(_report.nativeFunction);
      if (status != 0) throw StateError('loaf_chrome_install: $status');
    } on Object {
      // Don't leave a listener keeping the isolate alive.
      _report.close();
      rethrow;
    }
  }

  late final NativeCallable<_StateC> _report;
  bool _disposed = false;

  /// The window's state now. Calls below return the DLL's status: 0 is
  /// fine, below 0 is a failure.
  ChromeState get state {
    final bits = _disposed ? -4 : _state();
    return ChromeState.fromBits(bits < 0 ? 0 : bits);
  }

  int minimize() => _disposed ? -4 : _minimize();
  int toggleMaximize() => _disposed ? -4 : _toggleMaximize();
  int close() => _disposed ? -4 : _close();

  /// Hands the pointer to Windows' own move loop, so snapping works.
  int startDrag() => _disposed ? -4 : _startDrag();

  /// Where the maximize button is, in logical pixels from the window's
  /// top-left; all zero when it goes.
  int setMaxButtonRect(double x, double y, double w, double h) =>
      _disposed ? -4 : _setMaxButton(x, y, w, h);

  /// Gives the window its frame back. Once the DLL has let go, no new state
  /// arrives, so the listener closes.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _uninstall();
    _report.close();
  }
}
