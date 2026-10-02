/// Video played in place by the platform's own player, reading the file as
/// it downloads. The Swift end is
/// `darwin/loaf_media/Sources/loaf_media/VideoViewFactory.swift`; on Linux,
/// GStreamer draws into a texture under Flutter controls
/// (`linux_video.dart`).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'growing_file.dart';
import 'linux_video.dart';
import 'streams.dart';

/// The one playing video, by platform view id. Starting another pauses
/// this one.
final videoFocus = ValueNotifier<int?>(null);

const _channel = MethodChannel('moe.loaf.chat/media');
const _viewType = 'moe.loaf.chat/video';

/// The players on screen, by platform view id, for what the native side
/// says about each.
final _players = <int, _LoafVideoState>{};

/// Players whose widget has gone while picture in picture keeps them
/// playing. They still read their file until it closes.
final _floating = <int, ({GrowingFile file, VoidCallback? onRelease})>{};

/// What the native players say: ready, failed, playing, and picture in
/// picture starting or stopping.
var _listening = false;
void _listen() {
  if (_listening) return;
  _listening = true;
  _channel.setMethodCallHandler((call) async {
    final arguments = call.arguments as Map<Object?, Object?>;
    final view = arguments['view'];
    if (view is! int) return;
    switch (call.method) {
      case 'video.playing':
        final before = videoFocus.value;
        // A floating player has no widget left to pause itself.
        if (before != null && before != view && _floating.containsKey(before)) {
          _pause(before);
        }
        videoFocus.value = view;
      case 'video.ready':
        _players[view]?._ready();
      case 'video.failed':
        _players[view]?._failed();
      case 'video.pip':
        final active = arguments['active'] == true;
        _players[view]?._pip = active;
        // Over, or never started: harmless when nothing was floating.
        if (!active) _letGo(view);
      default:
        throw MissingPluginException('no ${call.method} here');
    }
  });
}

/// A floating player whose picture in picture is over: it stops reading.
void _letGo(int view) {
  final floating = _floating.remove(view);
  if (floating == null) return;
  VideoStreams.detach(floating.file);
  floating.onRelease?.call();
  if (videoFocus.value == view) videoFocus.value = null;
}

/// iOS: picture in picture may have started natively without Dart having
/// heard yet. The player is kept as floating until the native side answers;
/// if it isn't floating it is let go then, and if it is, when
/// picture in picture says it is over.
Future<void> _askFloating(int view) async {
  bool floating;
  try {
    floating =
        await _channel.invokeMethod<bool>('video.floating', {'view': view}) ??
        false;
  } on Exception catch (e) {
    debugPrint('[loaf media] floating $view: $e');
    floating = false;
  }
  if (!floating) _letGo(view);
}

Future<void> _pause(int view) async {
  try {
    await _channel.invokeMethod<void>('video.pause', {'view': view});
  } on Exception catch (e) {
    debugPrint('[loaf media] pause $view: $e');
  }
}

/// Plays [file] in place with the platform's player.
class LoafVideo extends StatefulWidget {
  const LoafVideo({
    super.key,
    required this.file,
    required this.mimeType,
    required this.aspect,
    this.onReady,
    this.onFailed,
    this.onHold,
    this.onRelease,
    this.onOpen,
  });

  final GrowingFile file;
  final String? mimeType;
  final double aspect;

  /// The player can start: an index at the end of the file has arrived.
  /// Until then the caller shows how far the download has got.
  final VoidCallback? onReady;

  /// The player can't play this file.
  final VoidCallback? onFailed;

  /// Called when this player starts reading [file], and [onRelease] once
  /// it no longer does: when the widget goes, or, if it went while in
  /// picture in picture, when that closes.
  final VoidCallback? onHold;
  final VoidCallback? onRelease;

  /// Linux: opens the file in another app when this player can't play it,
  /// offered beside "couldn't play this". The platform players elsewhere
  /// say so themselves.
  final VoidCallback? onOpen;

  /// Where this platform has a player: iOS, macOS and Linux. Asked of the
  /// target platform, as the player is chosen by it.
  static bool get supported => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS || TargetPlatform.linux => true,
    _ => false,
  };

  @override
  State<LoafVideo> createState() => _LoafVideoState();
}

class _LoafVideoState extends State<LoafVideo> {
  /// The platform view's id, once it exists.
  int? _view;
  ScrollPosition? _position;

  /// In picture in picture: scrolling the row away leaves it playing.
  var _pip = false;

  @override
  void initState() {
    super.initState();
    _listen();
    VideoStreams.attach(widget.file);
    widget.onHold?.call();
    videoFocus.addListener(_focusMoved);
  }

  @override
  void didUpdateWidget(LoafVideo old) {
    super.didUpdateWidget(old);
    if (old.file.id != widget.file.id) {
      VideoStreams.attach(widget.file);
      widget.onHold?.call();
      VideoStreams.detach(old.file);
      old.onRelease?.call();
    }
  }

  void _ready() => widget.onReady?.call();
  void _failed() => widget.onFailed?.call();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (position == _position) return;
    _position?.removeListener(_scrolled);
    _position = position?..addListener(_scrolled);
  }

  @override
  void dispose() {
    _position?.removeListener(_scrolled);
    videoFocus.removeListener(_focusMoved);
    final view = _view;
    if (view != null) _players.remove(view);
    if (view != null && (_pip || defaultTargetPlatform == TargetPlatform.iOS)) {
      // Floating, or maybe just starting to: it keeps reading until
      // picture in picture closes. Only iOS has it here.
      _floating[view] = (file: widget.file, onRelease: widget.onRelease);
      if (!_pip) _askFloating(view);
    } else {
      if (view != null && videoFocus.value == view) videoFocus.value = null;
      VideoStreams.detach(widget.file);
      widget.onRelease?.call();
    }
    super.dispose();
  }

  /// Whether this player was the one playing, as [videoFocus] last said.
  var _focused = false;

  /// Another player started: this one, if it was playing, stops.
  void _focusMoved() {
    final view = _view, playing = videoFocus.value;
    final was = _focused;
    _focused = view != null && playing == view;
    if (was && view != null && playing != null && playing != view) {
      _pause(view);
    }
  }

  /// Pauses this player once it has scrolled wholly out of view.
  void _scrolled() {
    final view = _view, position = _position;
    if (view == null || position == null || videoFocus.value != view) return;
    if (_pip) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    // The scroll offsets at which this box starts and ends at the
    // viewport's leading edge.
    final start = viewport.getOffsetToReveal(box, 0).offset;
    final extent = position.axis == Axis.vertical
        ? box.size.height
        : box.size.width;
    final shown =
        position.pixels < start + extent &&
        position.pixels + position.viewportDimension > start;
    if (shown) return;
    videoFocus.value = null;
    _pause(view);
  }

  void _created(int view) {
    _view = view;
    _players[view] = this;
  }

  @override
  Widget build(BuildContext context) {
    final params = {'id': widget.file.id, 'mime': widget.mimeType};
    // The view is made once with its file: a new file is a new player.
    final key = ValueKey(widget.file.id);
    final Widget player = switch (defaultTargetPlatform) {
      TargetPlatform.macOS => AppKitView(
        key: key,
        viewType: _viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _created,
      ),
      TargetPlatform.iOS => UiKitView(
        key: key,
        viewType: _viewType,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _created,
      ),
      TargetPlatform.linux => LinuxVideo(
        key: key,
        id: widget.file.id,
        aspect: widget.aspect,
        onCreated: _created,
        onFailed: _failed,
        onOpen: widget.onOpen,
      ),
      // [LoafVideo.supported] keeps this from being built elsewhere.
      final platform => ErrorWidget(
        UnsupportedError('no video player on $platform'),
      ),
    };
    return AspectRatio(aspectRatio: widget.aspect, child: player);
  }
}
