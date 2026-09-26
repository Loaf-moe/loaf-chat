/// The 7 SAS emoji as both ends draw them. The new device and the one
/// vouching for it show exactly this widget, so "do they match" compares
/// like with like.
library;

import 'package:flutter/material.dart';

import '../theme/loaf_theme.dart';
import 'verify_state.dart';

class EmojiCompare extends StatelessWidget {
  const EmojiCompare({super.key, required this.emoji});

  final List<SasEmoji> emoji;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _row(emoji.take(4).toList(), inset: false),
      const SizedBox(height: LoafSpace.x4),
      _row(emoji.skip(4).toList(), inset: true),
    ],
  );

  /// Cells share one width across both rows (flex 2 of 8), and the row of
  /// three is inset by half a cell each side, so the second row centres
  /// under the first. Names wrap rather than overflow at large text.
  Widget _row(List<SasEmoji> cells, {required bool inset}) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (inset) const Spacer(),
      for (final e in cells) Expanded(flex: 2, child: _Cell(e)),
      if (inset) const Spacer(),
    ],
  );
}

class _Cell extends StatelessWidget {
  const _Cell(this.e);

  final SasEmoji e;

  @override
  Widget build(BuildContext context) {
    final tokens = LoafTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(e.emoji, style: const TextStyle(fontSize: 34)),
        const SizedBox(height: LoafSpace.x1),
        Text(
          e.name,
          textAlign: TextAlign.center,
          style: loafBody(12, 500).copyWith(color: tokens.textMuted),
        ),
      ],
    );
  }
}
