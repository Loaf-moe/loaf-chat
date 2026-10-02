/// Video on Linux: GStreamer, through the Rust player in `linux/rust/`,
/// draws into a Flutter texture, and the controls are drawn here, since
/// Linux has no player UI of its own. The C end is
/// `linux/loaf_media_plugin.cc`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'video.dart' show videoFocus;

const _channel = MethodChannel('moe.loaf.chat/media');

/// How often the controls ask the player where it is. They redraw at this
/// rate anyway; frames reach the texture without the channel.
const _pollEvery = Duration(milliseconds: 250);

/// How long the controls stay once the pointer stops.
const _showFor = Duration(seconds: 2);

/// One native player, as last polled, and what the controls ask of it.
class _Player extends ChangeNotifier {
  _Player({required this.view, required this.texture});

  final int view;
  final int texture;

  var position = Duration.zero;

  /// Null until the file says.
  Duration? duration;
  var playing = false;
  var muted = false;
  var error = false;

  var _disposed = false;

  void _set(VoidCallback change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  Future<void> _call(String method, [Map<String, Object?> more = const {}]) =>
      _channel
          .invokeMethod<void>(method, {'view': view, ...more})
          .catchError((Object e) => debugPrint('[loaf media] $method: $e'));

  void play() {
    // One video plays at a time: whichever played before hears this and
    // pauses itself.
    videoFocus.value = view;
    _set(() => playing = true);
    unawaited(_call('video.play'));
  }

  void pause() {
    _set(() => playing = false);
    unawaited(_call('video.pause'));
  }

  void toggle() => playing ? pause() : play();

  void seek(Duration to) {
    _set(() => position = to);
    unawaited(_call('video.seek', {'ms': to.inMilliseconds}));
  }

  void toggleMute() {
    _set(() => muted = !muted);
    unawaited(_call('video.mute', {'muted': muted}));
  }

  Future<void> poll() async {
    Map<String, Object?>? state;
    try {
      state = await _channel.invokeMapMethod<String, Object?>('video.state', {
        'view': view,
      });
    } on Exception catch (e) {
      debugPrint('[loaf media] video.state: $e');
      return;
    }
    if (state == null || _disposed) return;
    final position = Duration(milliseconds: _int(state['position']) ?? 0);
    final ms = _int(state['duration']);
    final duration = ms == null || ms <= 0 ? null : Duration(milliseconds: ms);
    final playing = state['playing'] == true;
    final error = state['error'] == true;
    if (position == this.position &&
        duration == this.duration &&
        playing == this.playing &&
        error == this.error) {
      return;
    }
    _set(() {
      this.position = position;
      this.duration = duration;
      this.playing = playing;
      this.error = error;
    });
  }

  static int? _int(Object? value) => value is int ? value : null;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The player for one file on Linux: the texture, and Flutter controls
/// over it.
class LinuxVideo extends StatefulWidget {
  const LinuxVideo({
    super.key,
    required this.id,
    required this.aspect,
    this.onCreated,
    this.onFailed,
    this.onOpen,
  });

  /// The controls, while shown.
  @visibleForTesting
  static const controlsKey = ValueKey('loaf-video-controls');

  final String id;
  final double aspect;

  /// The native view's id, for what the native side says about it.
  final ValueChanged<int>? onCreated;

  /// No player could be made for the file.
  final VoidCallback? onFailed;

  /// Opens the file in another app, when this one can't play it. Null
  /// draws no "open it instead".
  final VoidCallback? onOpen;

  @override
  State<LinuxVideo> createState() => _LinuxVideoState();
}

class _LinuxVideoState extends State<LinuxVideo> {
  _Player? _player;
  var _createFailed = false;
  var _gone = false;
  Timer? _poll;

  /// The full-window route, while open.
  Route<void>? _route;

  @override
  void initState() {
    super.initState();
    unawaited(_create());
  }

  Future<void> _create() async {
    Map<String, Object?>? created;
    try {
      created = await _channel.invokeMapMethod<String, Object?>(
        'video.create',
        {'id': widget.id},
      );
    } on Exception catch (e) {
      debugPrint('[loaf media] video.create: $e');
    }
    final view = created?['view'], texture = created?['texture'];
    if (view is! int || texture is! int) {
      if (_gone) return;
      setState(() => _createFailed = true);
      widget.onFailed?.call();
      return;
    }
    if (_gone) {
      // The row went while the player was being made.
      unawaited(_dispose(view));
      return;
    }
    final player = _Player(view: view, texture: texture);
    setState(() => _player = player);
    widget.onCreated?.call(view);
    // The row's play was pressed to get here.
    player.play();
    _poll = Timer.periodic(_pollEvery, (_) {
      // Only while it can be seen: offstage routes turn tickers off. The
      // row is offstage under its own full window, which still needs it.
      if (_route != null ||
          TickerMode.getValuesNotifier(context).value.enabled) {
        unawaited(player.poll());
      }
    });
  }

  static Future<void> _dispose(int view) => _channel
      .invokeMethod<void>('video.dispose', {'view': view})
      .catchError((Object e) => debugPrint('[loaf media] video.dispose: $e'));

  void _openFullWindow() {
    final player = _player;
    final navigator = Navigator.maybeOf(context);
    if (player == null || navigator == null) return;
    final route = PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, _, _) => ColoredBox(
        color: Colors.black,
        child: Center(
          child: AspectRatio(
            aspectRatio: widget.aspect,
            child: _Surface(
              player: player,
              fullWindow: true,
              onWindow: () => Navigator.of(context).pop(),
              onOpen: widget.onOpen,
            ),
          ),
        ),
      ),
    );
    _route = route;
    unawaited(
      navigator.push(route).whenComplete(() {
        if (_route == route) _route = null;
      }),
    );
  }

  @override
  void dispose() {
    _gone = true;
    _poll?.cancel();
    final player = _player;
    if (player != null) unawaited(_dispose(player.view));
    final route = _route;
    if (route != null) {
      // The row went under the full window: that goes too. Not now, as the
      // tree is locked while it's torn down.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
        player?.dispose();
      });
    } else {
      player?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: widget.aspect,
      child: switch (_player) {
        _ when _createFailed => _Unplayable(onOpen: widget.onOpen),
        null => const ColoredBox(color: Colors.black),
        final player => _Surface(
          player: player,
          fullWindow: false,
          onWindow: Navigator.maybeOf(context) == null ? null : _openFullWindow,
          onOpen: widget.onOpen,
        ),
      },
    );
  }
}

/// The texture with the controls over it, in the row or the full window.
class _Surface extends StatefulWidget {
  const _Surface({
    required this.player,
    required this.fullWindow,
    required this.onWindow,
    required this.onOpen,
  });

  final _Player player;
  final bool fullWindow;

  /// Into the full window, or back out of it. Null draws no button.
  final VoidCallback? onWindow;
  final VoidCallback? onOpen;

  @override
  State<_Surface> createState() => _SurfaceState();
}

class _SurfaceState extends State<_Surface> {
  final _focus = FocusNode(debugLabel: 'video');
  var _shown = false;
  Timer? _hide;

  /// Where the scrubber is while dragged; it seeks once, on release.
  double? _drag;

  @override
  void initState() {
    super.initState();
    // The full window opens with its controls up, to show the way back.
    if (widget.fullWindow) {
      _shown = true;
      _hideLater();
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    _focus.dispose();
    super.dispose();
  }

  /// Shows the controls, until the pointer has been still for a while.
  void _show() {
    _hideLater();
    if (!_shown) setState(() => _shown = true);
  }

  void _hideLater() {
    _hide?.cancel();
    _hide = Timer(_showFor, () {
      if (!mounted) return;
      // Not mid-drag: the scrubber would go from under the pointer.
      if (_drag != null) return _hideLater();
      setState(() => _shown = false);
    });
  }

  void _hideNow() {
    if (_drag != null) return;
    _hide?.cancel();
    setState(() => _shown = false);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // Space on a button inside (open it instead, the controls) presses
    // that button, not play.
    if (event.logicalKey == LogicalKeyboardKey.space && node.hasPrimaryFocus) {
      widget.player.toggle();
      _show();
      return KeyEventResult.handled;
    }
    final onWindow = widget.onWindow;
    if (widget.fullWindow &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        onWindow != null) {
      onWindow();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.player,
    builder: (context, child) => Focus(
      focusNode: _focus,
      autofocus: widget.fullWindow,
      // Failed, it has nothing for the keyboard; Tab goes to the link.
      skipTraversal: widget.player.error,
      onKeyEvent: _key,
      child: child!,
    ),
    child: MouseRegion(
      onEnter: (_) => _show(),
      onHover: (_) => _show(),
      onExit: (_) => _hideNow(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _focus.requestFocus();
          _show();
        },
        child: ListenableBuilder(
          listenable: widget.player,
          builder: (context, _) {
            final player = widget.player;
            if (player.error) return _Unplayable(onOpen: widget.onOpen);
            return Stack(
              fit: StackFit.expand,
              children: [
                Texture(textureId: player.texture),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: _shown ? _controls(context, player) : null,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _controls(BuildContext context, _Player player) {
    final duration = player.duration;
    final at = _drag == null
        ? player.position
        : Duration(milliseconds: _drag!.round());
    final style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: Colors.white);
    final onWindow = widget.onWindow;
    Widget button(IconData icon, String tip, VoidCallback onPressed) =>
        IconButton(
          icon: Icon(icon),
          tooltip: tip,
          color: Colors.white,
          visualDensity: VisualDensity.compact,
          onPressed: () {
            onPressed();
            _show();
          },
        );
    return Material(
      key: LinuxVideo.controlsKey,
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0x99000000), Color(0x00000000)],
          ),
        ),
        child: Row(
          children: [
            button(
              player.playing ? Icons.pause : Icons.play_arrow,
              player.playing ? 'pause' : 'play',
              player.toggle,
            ),
            Text(
              duration == null
                  ? _clock(at)
                  : '${_clock(at)} / ${_clock(duration)}',
              style: style,
            ),
            Expanded(
              // Nothing to scrub over until the length is known.
              child: duration == null
                  ? const SizedBox.shrink()
                  : Slider(
                      max: duration.inMilliseconds.toDouble(),
                      value: (_drag ?? player.position.inMilliseconds)
                          .clamp(0, duration.inMilliseconds)
                          .toDouble(),
                      activeColor: Colors.white,
                      inactiveColor: Colors.white38,
                      onChangeStart: (v) => setState(() => _drag = v),
                      onChanged: (v) => setState(() => _drag = v),
                      onChangeEnd: (v) {
                        setState(() => _drag = null);
                        player.seek(Duration(milliseconds: v.round()));
                        _show();
                      },
                    ),
            ),
            button(
              player.muted ? Icons.volume_off : Icons.volume_up,
              player.muted ? 'unmute' : 'mute',
              player.toggleMute,
            ),
            if (onWindow != null)
              button(
                widget.fullWindow ? Icons.fullscreen_exit : Icons.fullscreen,
                widget.fullWindow ? 'leave full window' : 'full window',
                onWindow,
              ),
          ],
        ),
      ),
    );
  }
}

String _clock(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// What a video the player can't play says, with the way forward: another
/// app may well play the file.
class _Unplayable extends StatelessWidget {
  const _Unplayable({required this.onOpen});

  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Colors.white70);
    final onOpen = this.onOpen;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              onOpen == null ? "couldn't play this" : "couldn't play this · ",
              style: style,
            ),
            if (onOpen != null)
              // A link, as on the desktop: the click cursor, and reached by
              // the keyboard.
              TextButton(
                onPressed: onOpen,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: Colors.white,
                  enabledMouseCursor: SystemMouseCursors.click,
                ),
                child: Text(
                  'open it instead',
                  style: style?.copyWith(
                    color: Colors.white,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
