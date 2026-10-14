/// How [WindowChromeController] reaches the window it draws the buttons
/// for: the runner's `loaf/window` channel on macOS and Linux, and on
/// Windows the Rust crate in `packages/loaf_chrome`, called over `dart:ffi`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:loaf_chrome/loaf_chrome.dart';

/// Reports arrive in the runner's own shape, which
/// `WindowState.fromPlatform` reads.
typedef WindowReport = Map<Object?, Object?>;

abstract interface class WindowRunner {
  /// Starts listening, and answers the window's state now; null when there
  /// is no runner window to draw buttons for, which leaves the OS's frame.
  Future<WindowReport?> attach(void Function(WindowReport) onChange);

  /// Asks the window for [method]: `minimize`, `toggleMaximize`, `close`,
  /// `startDrag`, `titlebarDoubleClick`, or `setMaxButtonRect` with
  /// `{x, y, w, h}` in logical pixels. A failure is logged, never thrown:
  /// a button that does nothing beats an exception on every click.
  Future<void> send(String method, [Object? arguments]);

  void detach();
}

/// The runner on this platform.
WindowRunner pickWindowRunner({TargetPlatform? platform}) =>
    switch (platform ?? defaultTargetPlatform) {
      TargetPlatform.windows => NativeWindowRunner(),
      _ => ChannelWindowRunner(),
    };

/// The `loaf/window` method channel the macOS and Linux runners answer.
class ChannelWindowRunner implements WindowRunner {
  ChannelWindowRunner([this._channel = const MethodChannel('loaf/window')]);

  final MethodChannel _channel;

  @override
  Future<WindowReport?> attach(void Function(WindowReport) onChange) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stateChanged') {
        final args = call.arguments;
        if (args is Map) onChange(args);
      }
      return null;
    });
    try {
      return await _channel.invokeMapMethod<Object?, Object?>('state');
    } on MissingPluginException {
      // A runner that predates the channel keeps its own frame.
    } on PlatformException catch (e) {
      debugPrint('[loaf window] no window state: $e');
    }
    return null;
  }

  @override
  Future<void> send(String method, [Object? arguments]) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // No runner channel: nothing to tell.
    } on PlatformException catch (e) {
      debugPrint('[loaf window] $method failed: $e');
    }
  }

  @override
  void detach() => _channel.setMethodCallHandler(null);
}

/// Windows: [FramelessWindow] takes the frame away and reports state.
class NativeWindowRunner implements WindowRunner {
  FramelessWindow? _window;

  static WindowReport _report(ChromeState s) => {
    'maximized': s.maximized,
    'focused': s.focused,
    'maxHovered': s.maxHovered,
  };

  @override
  Future<WindowReport?> attach(void Function(WindowReport) onChange) async {
    try {
      final window = _window ??= FramelessWindow((s) => onChange(_report(s)));
      return _report(window.state);
    } on Object catch (e) {
      // No DLL, or no window on this thread: the frame stays the OS's.
      debugPrint('[loaf window] no frameless window: $e');
      return null;
    }
  }

  @override
  Future<void> send(String method, [Object? arguments]) async {
    final window = _window;
    if (window == null) return;
    final status = switch (method) {
      'minimize' => window.minimize(),
      // Windows' title bar maximizes or restores on a double-click.
      'toggleMaximize' || 'titlebarDoubleClick' => window.toggleMaximize(),
      'close' => window.close(),
      'startDrag' => window.startDrag(),
      'setMaxButtonRect' when arguments is Map => window.setMaxButtonRect(
        _num(arguments['x']),
        _num(arguments['y']),
        _num(arguments['w']),
        _num(arguments['h']),
      ),
      _ => null,
    };
    if (status == null) {
      debugPrint('[loaf window] $method: not a window call');
    } else if (status != 0) {
      debugPrint('[loaf window] $method failed: $status');
    }
  }

  static double _num(Object? v) => v is num ? v.toDouble() : 0;

  @override
  void detach() {
    _window?.dispose();
    _window = null;
  }
}
