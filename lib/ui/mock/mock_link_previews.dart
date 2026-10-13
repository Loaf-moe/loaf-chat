/// The mock backend's [LinkPreviews]: a few pages it knows by heart.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../model/link_previews.dart';

class MockLinkPreviews implements LinkPreviews {
  static final _pages = <Uri, LinkPreview>{
    Uri.parse('https://loaf.moe/levain'): LinkPreview.of(
      title: 'A levain that keeps its word',
      description:
          'Equal parts flour and water, a spoon of starter, and a warm '
          'corner overnight.',
      image: const AssetImage('assets/mock/media/oven.jpg'),
    )!,
    Uri.parse('https://loaf.moe/crumb'): LinkPreview.of(
      title: 'Reading a crumb',
      description: 'What the holes say about the proof.',
    )!,
  };

  final _known = <Uri, ValueNotifier<LinkPreviewState>>{};

  @override
  ValueListenable<LinkPreviewState> of(Uri link) => _known.putIfAbsent(
    link,
    () => ValueNotifier(switch (_pages[link]) {
      final page? => LinkPreviewReady(page),
      null => const LinkPreviewNone(),
    }),
  );
}
