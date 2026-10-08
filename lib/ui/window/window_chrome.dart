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
  WindowChromeController({this._channel = const MethodChannel('loaf/window')});

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
    if (call.method == 'stateChanged') {
      final args = call.arguments;
      if (args is Map) _apply(args);
    }
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
    // buttons on the left) shrink to fit rather than overflow. Each side
    // gets the whole width when it is alone; a spacer beside it would halve
    // that and scale the buttons down with it.
    return WindowDragArea(
      child: SizedBox(
        height: WindowMetrics.band,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: LoafSpace.x3),
          child: Row(
            children: [
              if (leading.isNotEmpty)
                const Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: WindowControls(WindowEdge.leading, inBand: true),
                    ),
                  ),
                ),
              if (trailing.isNotEmpty)
                const Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: WindowControls(WindowEdge.trailing, inBand: true),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

VoidCallback _action(WindowChromeController c, WindowButton b) => switch (b) {
  WindowButton.minimize => c.minimize,
  WindowButton.maximize => c.toggleMaximize,
  WindowButton.close => c.close,
};

/// What a screen reader (and a pill's tooltip) calls a button. A Mac's
/// green dot zooms, so it says so; elsewhere it maximizes or restores.
String _label(WindowButton b, {required bool maximized}) => switch (b) {
  WindowButton.close => 'Close window',
  WindowButton.minimize => 'Minimize window',
  WindowButton.maximize =>
    maximized
        ? 'Restore window'
        : defaultTargetPlatform == TargetPlatform.macOS
        ? 'Zoom window'
        : 'Maximize window',
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
              Semantics(
                button: true,
                label: _label(b, maximized: widget.controller.state.maximized),
                excludeSemantics: true,
                onTap: _action(widget.controller, b),
                child: GestureDetector(
                  key: ValueKey('window-${b.name}'),
                  onTap: _action(widget.controller, b),
                  child: AnimatedContainer(
                    duration: LoafMotion.fast,
                    width: 12,
                    height: 12,
                    // Coloured whenever the window is focused, as a Mac's
                    // are: grey dots at rest read as a "more" menu, not as
                    // the window's buttons.
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: focused || _hover
                          ? switch (b) {
                              WindowButton.close => tokens.accent,
                              WindowButton.minimize => tokens.idle,
                              WindowButton.maximize => tokens.online,
                            }
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
    if (!mounted || onPlaced == null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
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
      // A resize moves the button without rebuilding it; depending on the
      // size makes it rebuild, so the runner hears the new position.
      MediaQuery.sizeOf(context);
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
    final label = _label(widget.button, maximized: widget.state.maximized);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // The tooltip's own semantics are off: the button already says it.
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          onTap: widget.onTap,
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
        ),
      ),
    );
  }
}
