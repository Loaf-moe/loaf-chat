/// The 日本 theme's decor: sakura petals drifting behind the conversation and
/// a little Shinkansen crossing above the composer, both lifted from the
/// "日本 Again" trip checklist.
///
/// Each draws nothing unless the theme asks for sakura, never takes a tap or
/// a screen reader's attention, and holds still when the system asks for
/// less motion.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'loaf_theme.dart';

bool _wantsSakura(BuildContext context) =>
    LoafTokens.of(context).decor == LoafDecor.sakura;

/// Fills its parent; put it behind the content in a `Stack`.
class SakuraPetals extends StatelessWidget {
  const SakuraPetals({super.key});

  @override
  Widget build(BuildContext context) {
    if (!_wantsSakura(context) || MediaQuery.disableAnimationsOf(context)) {
      return const SizedBox.shrink();
    }
    return const IgnorePointer(child: ExcludeSemantics(child: _Petals()));
  }
}

class _Petals extends StatefulWidget {
  const _Petals();

  @override
  State<_Petals> createState() => _PetalsState();
}

class _PetalsState extends State<_Petals> with SingleTickerProviderStateMixin {
  final _elapsed = ValueNotifier(Duration.zero);
  late final Ticker _ticker;
  // Seeded per mount, so every mount falls the same petals and tests see one
  // picture; a shared Random would reshuffle after the first remount.
  final _petals = _seededPetals();

  static List<_Petal> _seededPetals() {
    final random = math.Random(1016);
    return List.generate(18, (_) => _Petal(random), growable: false);
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) => _elapsed.value = elapsed)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsed.dispose();
    super.dispose();
  }

  @override
  // Its own layer: the painter repaints every frame, and without a boundary
  // that would re-record the timeline stacked with it.
  // Clipped outside the boundary so the layer's own bounds already cut the
  // petals that sway past the edge; CustomPaint alone never clips.
  Widget build(BuildContext context) => SizedBox.expand(
    child: ClipRect(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _PetalPainter(
            _petals,
            _elapsed,
            LoafTokens.of(context).accent,
          ),
        ),
      ),
    ),
  );
}

/// Where a petal starts and how it moves. Its position is a pure function of
/// time, so the painter needs no per-frame state.
class _Petal {
  _Petal(math.Random r)
    : x = r.nextDouble(),
      y = r.nextDouble(),
      size = 6 + r.nextDouble() * 7,
      fall = 0.04 + r.nextDouble() * 0.06,
      spin = r.nextDouble() * 6,
      sway = r.nextDouble() * 6;

  final double x, y, size, fall, spin, sway;
}

class _PetalPainter extends CustomPainter {
  _PetalPainter(this.petals, this.elapsed, this.color)
    : super(repaint: elapsed);

  final List<_Petal> petals;
  final ValueNotifier<Duration> elapsed;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final t = elapsed.value.inMicroseconds / Duration.microsecondsPerSecond;
    final paint = Paint()..color = color.withValues(alpha: 0.55);
    for (final p in petals) {
      // Wraps from just below the bottom edge to just above the top one.
      final y = (p.y + p.fall * t) % 1.1 - 0.05;
      final x = p.x + 0.02 * math.sin(t / 1.6 + p.sway);
      final s = p.size;
      canvas
        ..save()
        ..translate(x * size.width, y * size.height)
        ..rotate(p.spin + 0.6 * t)
        ..drawPath(
          Path()
            ..moveTo(0, -s)
            ..cubicTo(s * .9, -s * .6, s * .7, s * .6, 0, s)
            ..cubicTo(-s * .7, s * .6, -s * .9, -s * .6, 0, -s),
          paint,
        )
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_PetalPainter old) =>
      old.color != color || old.petals != petals;
}

/// A strip of track above the composer with the train running along it.
class ShinkansenRail extends StatefulWidget {
  const ShinkansenRail({super.key});

  static const height = 46.0;

  @override
  State<ShinkansenRail> createState() => _ShinkansenRailState();
}

class _ShinkansenRailState extends State<ShinkansenRail>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The view's inset changes don't notify View.of dependents, and the rail is
  // built const, so nothing else would rebuild it when the keyboard moves.
  @override
  void didChangeMetrics() => setState(() {});

  @override
  Widget build(BuildContext context) {
    if (!_wantsSakura(context)) return const SizedBox.shrink();
    // On a phone the keyboard leaves little timeline; the train can wait.
    // Read from the view, not MediaQuery: the Scaffold above this strips the
    // keyboard inset from its body's MediaQuery, so that would never fire.
    if (View.of(context).viewInsets.bottom > 0) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: ExcludeSemantics(
        child: SizedBox(
          height: ShinkansenRail.height,
          child: _Rail(moving: !MediaQuery.disableAnimationsOf(context)),
        ),
      ),
    );
  }
}

class _Rail extends StatefulWidget {
  const _Rail({required this.moving});

  final bool moving;

  @override
  State<_Rail> createState() => _RailState();
}

class _RailState extends State<_Rail> with SingleTickerProviderStateMixin {
  final _elapsed = ValueNotifier(Duration.zero);
  late final Ticker _ticker = createTicker((e) => _elapsed.value = e);

  @override
  void initState() {
    super.initState();
    if (widget.moving) _ticker.start();
  }

  @override
  void didUpdateWidget(_Rail old) {
    super.didUpdateWidget(old);
    if (widget.moving && !_ticker.isActive) _ticker.start();
    if (!widget.moving && _ticker.isActive) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _elapsed.dispose();
    super.dispose();
  }

  @override
  // Its own layer, so the train's frames don't repaint the composer.
  // The train enters and leaves past the rail's edges; clip it so it never
  // draws over the sidebar beside the timeline on desktop.
  Widget build(BuildContext context) => SizedBox.expand(
    child: ClipRect(
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _RailPainter(
            elapsed: _elapsed,
            moving: widget.moving,
            tokens: LoafTokens.of(context),
          ),
        ),
      ),
    ),
  );
}

class _RailPainter extends CustomPainter {
  _RailPainter({
    required this.elapsed,
    required this.moving,
    required this.tokens,
  }) : super(repaint: elapsed);

  final ValueNotifier<Duration> elapsed;
  final bool moving;
  final LoafTokens tokens;

  /// The train's own drawing space: the checklist's SVG viewBox.
  static const _trainWidth = 300.0;
  static const _trainHeight = 34.0;
  static const _crossing = 14.0; // seconds per pass

  @override
  void paint(Canvas canvas, Size size) {
    _paintTrack(canvas, size);

    final t = elapsed.value.inMicroseconds / Duration.microsecondsPerSecond;
    final double left;
    final double bob;
    if (moving) {
      final progress = (t % _crossing) / _crossing;
      left = -_trainWidth - 20 + progress * (size.width + _trainWidth + 40);
      // Up a pixel and back once a second, like a carriage on the joints.
      bob = -(1 - math.cos(2 * math.pi * t)) / 2;
    } else {
      left = size.width - _trainWidth - 16;
      bob = 0;
    }
    canvas
      ..save()
      ..translate(left, size.height - 9 - _trainHeight + bob);
    _paintTrain(canvas);
    canvas.restore();
  }

  void _paintTrack(Canvas canvas, Size size) {
    final paint = Paint()..color = tokens.textMuted.withValues(alpha: 0.45);
    final top = size.height - 6 - 3;
    for (var x = 0.0; x < size.width; x += 22) {
      canvas.drawRect(Rect.fromLTWH(x, top, 14, 3), paint);
    }
  }

  void _paintTrain(Canvas canvas) {
    final body = Paint()..color = tokens.card;
    final outline = Paint()
      ..color = tokens.textStrong
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final stripe = Paint()..color = tokens.accent;
    final glass = Paint()..color = tokens.textStrong.withValues(alpha: 0.8);
    final wheel = Paint()..color = tokens.textStrong;

    final cars = [
      // Rear car.
      Path()
        ..moveTo(4, 8)
        ..quadraticBezierTo(4, 4, 8, 4)
        ..lineTo(92, 4)
        ..lineTo(92, 28)
        ..lineTo(8, 28)
        ..quadraticBezierTo(4, 28, 4, 24)
        ..close(),
      // Middle car.
      Path()..addRect(const Rect.fromLTRB(96, 4, 184, 28)),
      // Lead car, with the long nose.
      Path()
        ..moveTo(188, 4)
        ..lineTo(236, 4)
        ..cubicTo(262, 4, 284, 14, 296, 26)
        ..quadraticBezierTo(297, 28, 294, 28)
        ..lineTo(188, 28)
        ..close(),
    ];
    for (final car in cars) {
      canvas
        ..drawPath(car, body)
        ..drawPath(car, outline);
    }

    canvas
      ..drawRect(const Rect.fromLTWH(4, 19, 88, 3), stripe)
      ..drawRect(const Rect.fromLTWH(96, 19, 88, 3), stripe)
      ..drawPath(
        Path()
          ..moveTo(188, 19)
          ..lineTo(274, 19)
          ..quadraticBezierTo(279, 20.5, 282, 22)
          ..lineTo(188, 22)
          ..close(),
        stripe,
      );

    for (final x in const <double>[
      12.0,
      28,
      44,
      60,
      76,
      104,
      120,
      136,
      152,
      168,
      196,
      212,
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 9, 10, 6),
          const Radius.circular(2),
        ),
        glass,
      );
    }
    // The driver's windscreen.
    canvas.drawPath(
      Path()
        ..moveTo(244, 7)
        ..cubicTo(256, 8, 266, 12, 272, 16)
        ..lineTo(246, 16)
        ..quadraticBezierTo(243, 16, 243, 13)
        ..close(),
      glass,
    );

    for (final x in const <double>[20.0, 76, 112, 168, 204, 262]) {
      canvas.drawCircle(Offset(x, 30), 2.5, wheel);
    }
  }

  @override
  bool shouldRepaint(_RailPainter old) =>
      old.moving != moving || old.tokens != tokens;
}
