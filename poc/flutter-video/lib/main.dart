// The GPUI video PoC's scenario in Flutter, through the Dart app's video path.
//
// Takes the same flags as gpui-video-poc, so tools/measure.py and
// tools/check_colours.py drive either:
//
//   flutter_video_poc [--tiles N] [--res WxH] [--fps F] [--seconds S] [--idle]
//
// Each tile is RTCVideoView's widget tree (flutter_webrtc
// lib/src/native/rtc_video_view_impl.dart, contain, not mirrored) over a
// Texture fed by linux/runner/video_harness.cc, with the PoC's label on top.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('poc/video');

class Args {
  int tiles = 4, width = 1280, height = 720, fps = 30, seconds = 0;
  bool idle = false;

  Args.parse(List<String> argv) {
    final it = argv.iterator;
    String value(String flag) {
      if (!it.moveNext()) throw ArgumentError('$flag needs a value');
      return it.current;
    }

    while (it.moveNext()) {
      switch (it.current) {
        case '--tiles':
          tiles = int.parse(value('--tiles'));
        case '--fps':
          fps = int.parse(value('--fps'));
        case '--seconds':
          seconds = int.parse(value('--seconds'));
        case '--res':
          final parts = value('--res').split('x');
          width = int.parse(parts[0]);
          height = int.parse(parts[1]);
        case '--idle':
          idle = true;
        default:
          throw ArgumentError('unknown argument ${it.current}');
      }
    }
    if (tiles <= 0 || fps <= 0) {
      throw ArgumentError('--tiles and --fps must be positive');
    }
  }
}

void main(List<String> argv) {
  final args = Args.parse(argv);
  WidgetsFlutterBinding.ensureInitialized();
  runApp(PocApp(args));
}

class PocApp extends StatefulWidget {
  const PocApp(this.args, {super.key});
  final Args args;

  @override
  State<PocApp> createState() => _PocAppState();
}

class _PocAppState extends State<PocApp> {
  List<int>? _textures;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final a = widget.args;
    final ids = await _channel.invokeListMethod<int>('start', {
      'tiles': a.tiles,
      'width': a.width,
      'height': a.height,
      'fps': a.fps,
      'idle': a.idle,
    });
    setState(() => _textures = ids);

    var last = (DateTime.now(), 0, 0);
    var elapsed = 0;
    Timer.periodic(const Duration(seconds: 5), (timer) async {
      elapsed += 5;
      final stats = (await _channel.invokeListMethod<int>('stats'))!;
      final (delivered, copies) = (stats[0], stats[1]);
      final secs = DateTime.now().difference(last.$1).inMicroseconds / 1e6;
      stderr.writeln(
        '${elapsed.toString().padLeft(4)}s  '
        'frames delivered ${((delivered - last.$2) / secs).toStringAsFixed(1)}/s  '
        'tile paints ${((copies - last.$3) / secs).toStringAsFixed(1)}/s',
      );
      last = (DateTime.now(), delivered, copies);
      if (a.seconds > 0 && elapsed >= a.seconds) {
        timer.cancel();
        await _channel.invokeMethod('stop');
        exit(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.args;
    final textures = _textures;
    final columns = sqrt(a.tiles).ceil();
    final rows = <Widget>[];
    if (textures != null) {
      for (var i = 0; i < textures.length; i += columns) {
        final row = textures.sublist(i, min(i + columns, textures.length));
        rows.add(Expanded(
          child: Row(
            spacing: 4,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (j, id) in row.indexed)
                Expanded(
                  child: Tile(
                    textureId: id,
                    aspectRatio: a.width / a.height,
                    name: 'tile ${i + j} · ${a.width}x${a.height} @ ${a.fps} fps',
                  ),
                ),
            ],
          ),
        ));
      }
    }
    return WidgetsApp(
      color: Colors.black,
      debugShowCheckedModeBanner: false,
      builder: (context, _) => ColoredBox(
        color: Colors.black,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(spacing: 4, children: rows),
        ),
      ),
    );
  }
}

class Tile extends StatelessWidget {
  const Tile({
    super.key,
    required this.textureId,
    required this.aspectRatio,
    required this.name,
  });

  final int textureId;
  final double aspectRatio;
  final String name;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF101010),
      child: Stack(
        fit: StackFit.expand,
        children: [
          VideoView(textureId: textureId, aspectRatio: aspectRatio),
          Positioned(
            top: 8,
            left: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  name,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// RTCVideoView's build, with the renderer's aspect ratio fixed (the real
/// one only rebuilds when the video size changes) and no mirroring.
class VideoView extends StatelessWidget {
  const VideoView({super.key, required this.textureId, required this.aspectRatio});

  final int textureId;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Center(
        child: SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: FittedBox(
            clipBehavior: Clip.hardEdge,
            fit: BoxFit.contain,
            child: Center(
              child: SizedBox(
                width: constraints.maxHeight * aspectRatio,
                height: constraints.maxHeight,
                child: Transform(
                  transform: Matrix4.identity()..rotateY(0.0),
                  alignment: FractionalOffset.center,
                  child: Texture(
                    textureId: textureId,
                    filterQuality: FilterQuality.low,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
