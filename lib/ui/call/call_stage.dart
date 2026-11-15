/// How a call's tiles are arranged: a grid, or a spotlight with a filmstrip.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/loaf_theme.dart';
import 'call_tile.dart';

typedef TileBuilder = Widget Function(TileInfo info, {required bool small});

/// Below this width the filmstrip runs along the bottom rather than the
/// right, and the grid tops out at two columns.
const _narrow = 700.0;

const _gap = LoafSpace.x2;

class CallStage extends StatelessWidget {
  const CallStage({
    super.key,
    required this.tiles,
    required this.tileBuilder,
    this.spotlight,
    this.compact = false,
  });

  final List<TileInfo> tiles;
  final TileBuilder tileBuilder;

  /// The id of the tile on the stage, if any.
  final String? spotlight;

  /// One row of tiles, for the DM panel's compact size.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (compact) return _strip(constraints);
        final star = tiles.where((t) => t.id == spotlight).firstOrNull;
        if (star != null && tiles.length > 1) {
          return _spotlight(constraints, star);
        }
        return _grid(constraints);
      },
    );
  }

  Widget _strip(BoxConstraints c) {
    final width = math.min(
      (c.maxWidth - _gap * (tiles.length - 1)) / tiles.length,
      c.maxHeight * 1.6,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final (i, t) in tiles.indexed) ...[
          if (i > 0) const SizedBox(width: _gap),
          SizedBox(width: width, child: tileBuilder(t, small: true)),
        ],
      ],
    );
  }

  Widget _spotlight(BoxConstraints c, TileInfo star) {
    final rest = [
      for (final t in tiles)
        if (t.id != star.id) t,
    ];
    final wide = c.maxWidth >= _narrow;
    final stage = KeyedSubtree(
      key: const ValueKey('spotlight'),
      child: tileBuilder(star, small: false),
    );
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: stage),
          const SizedBox(width: _gap),
          SizedBox(
            width: 200,
            child: ListView.separated(
              itemCount: rest.length,
              separatorBuilder: (_, _) => const SizedBox(height: _gap),
              itemBuilder: (_, i) => SizedBox(
                height: 120,
                child: tileBuilder(rest[i], small: true),
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: stage),
        const SizedBox(height: _gap),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: rest.length,
            separatorBuilder: (_, _) => const SizedBox(width: _gap),
            itemBuilder: (_, i) =>
                SizedBox(width: 128, child: tileBuilder(rest[i], small: true)),
          ),
        ),
      ],
    );
  }

  Widget _grid(BoxConstraints c) {
    final n = tiles.length;
    final cols = columnsFor(n, c.maxWidth, c.maxHeight);
    final (width, fitted) = _tileSize(n, cols, c.maxWidth, c.maxHeight);
    const minHeight = 140.0;
    final height = math.max(fitted, minHeight);
    // Past what fits, the grid scrolls rather than shrinking tiles into
    // stamps. Short of filling the pane, it sits in the middle.
    return Center(
      child: SingleChildScrollView(
        child: Wrap(
          spacing: _gap,
          runSpacing: _gap,
          alignment: WrapAlignment.center,
          children: [
            for (final t in tiles)
              SizedBox(
                width: width,
                height: height,
                child: tileBuilder(t, small: false),
              ),
          ],
        ),
      ),
    );
  }
}

/// The tallest a tile on a computer is for its width: 4:3. A camera is
/// wider than that, and a taller tile crops it to a sliver.
const _tallest = 3 / 4;

/// How large each of [count] tiles is in [cols] columns of a [width] by
/// [height] pane.
(double, double) _tileSize(int count, int cols, double width, double height) {
  final rows = (count / cols).ceil();
  final w = (width - _gap * (cols - 1)) / cols;
  final h = (height - _gap * (rows - 1)) / rows;
  return (w, width < _narrow ? h : math.min(h, w * _tallest));
}

/// Columns for [count] tiles in a [width] by [height] pane. A phone stacks
/// two, then goes to two columns. A computer takes whichever number shows
/// the largest 16:9 picture in each tile, so a tall window gets fewer
/// columns and a wide one more.
int columnsFor(int count, double width, double height) {
  if (width < _narrow) return count <= 2 ? 1 : 2;
  var best = 1;
  var most = 0.0;
  for (var cols = 1; cols <= count; cols++) {
    final (w, h) = _tileSize(count, cols, width, height);
    final shown = math.min(w, h * 16 / 9) * math.min(h, w * 9 / 16);
    if (shown > most) {
      most = shown;
      best = cols;
    }
  }
  return best;
}
