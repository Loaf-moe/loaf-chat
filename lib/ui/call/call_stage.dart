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
    final cols = columnsFor(n, c.maxWidth);
    final rows = (n / cols).ceil();
    final width = (c.maxWidth - _gap * (cols - 1)) / cols;
    const minHeight = 140.0;
    final fitted = (c.maxHeight - _gap * (rows - 1)) / rows;
    final height = math.max(fitted, minHeight);
    // Past what fits, the grid scrolls rather than shrinking tiles into
    // stamps.
    return SingleChildScrollView(
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
    );
  }
}

/// Columns for [count] tiles at [width]. A phone stacks two, then goes to
/// two columns; a computer spreads out to three or four as it has room.
int columnsFor(int count, double width) {
  if (width < _narrow) return count <= 2 ? 1 : 2;
  final most = width >= 1100 ? 4 : 3;
  return math.min(count, count == 4 ? 2 : most);
}
