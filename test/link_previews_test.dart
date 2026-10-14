import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/link_previews.dart';

void main() {
  group('LinkPreview.of', () {
    test('a title and a description lose the space around them', () {
      final preview = LinkPreview.of(
        title: '  Bread  ',
        description: '\nrises ',
      );
      expect(preview?.title, 'Bread');
      expect(preview?.description, 'rises');
    });

    test('blank text counts as none', () {
      final preview = LinkPreview.of(title: '   ', description: 'rises');
      expect(preview?.title, isNull);
      expect(preview?.description, 'rises');
    });

    test('a picture alone is a preview', () {
      final image = MemoryImage(Uint8List(0));
      expect(LinkPreview.of(image: image)?.image, image);
    });

    test('with nothing to draw there is none', () {
      expect(LinkPreview.of(), isNull);
      expect(LinkPreview.of(title: ' ', description: ''), isNull);
    });
  });

  testWidgets('without a scope, no link has a preview', (tester) async {
    late LinkPreviews previews;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          previews = LinkPreviewsScope.of(context);
          return const SizedBox();
        },
      ),
    );
    expect(
      previews.of(Uri.parse('https://loaf.moe')).value,
      isA<LinkPreviewNone>(),
    );
  });
}
