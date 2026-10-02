/// Video played in place by the platform's own player, reading the file as
/// it downloads. The Swift end is
/// `darwin/loaf_media/Sources/loaf_media/VideoViewFactory.swift`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'growing_file.dart';
import 'streams.dart';

/// The one playing video, by platform view id. Starting another pauses
/// this one.
final videoFocus = ValueNotifier<int?>(null);

const _channel = MethodChannel('moe.loaf.chat/media');
const _viewType = 'moe.loaf.chat/video';

/// The native players say when they start; nothing else comes this way.
var _listening = false;
void _listen() {
  if (_listening) return;
  _listening = true;
  _channel.setMethodCallHandler((call) async {
    if (call.method != 'video.playing') {
      throw MissingPluginException('no ${call.method} here');
    }
    final view = (call.arguments as Map<Object?, Object?>)['view'];
    if (view is int) videoFocus.value = view;
  });
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
  });

  final GrowingFile file;
  final String? mimeType;
  final double aspect;

  /// Where this platform has a player: iOS and macOS here, Linux from
  /// Task 7. Asked of the target platform, as the player is chosen by it.
  static bool get supported => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => true,
    _ => false,
  };

  @override
  State<LoafVideo> createState() => _LoafVideoState();
}

class _LoafVideoState extends State<LoafVideo> {
  /// The platform view's id, once it exists.
  int? _view;
  ScrollPosition? _position;

  @override
  void initState() {
    super.initState();
    _listen();
    VideoStreams.attach(widget.file);
    videoFocus.addListener(_focusMoved);
  }

  @override
  void didUpdateWidget(LoafVideo old) {
    super.didUpdateWidget(old);
    if (old.file.id != widget.file.id) {
      VideoStreams.attach(widget.file);
      VideoStreams.detach(old.file);
    }
  }

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
    if (_view != null && videoFocus.value == _view) videoFocus.value = null;
    VideoStreams.detach(widget.file);
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

  void _created(int view) => _view = view;

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
      // [LoafVideo.supported] keeps this from being built elsewhere.
      final platform => ErrorWidget(
        UnsupportedError('no video player on $platform'),
      ),
    };
    return AspectRatio(aspectRatio: widget.aspect, child: player);
  }
}
