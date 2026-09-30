import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/models.dart';
import 'package:loaf_native/ui/theme/loaf_theme.dart';
import 'package:loaf_native/ui/widgets/avatar_images.dart';
import 'package:loaf_native/ui/widgets/loaf_avatar.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

BoxDecoration _decoration(WidgetTester tester) =>
    tester
            .widget<Container>(
              find.descendant(
                of: find.byType(LoafAvatar),
                matching: find.byType(Container),
              ),
            )
            .decoration!
        as BoxDecoration;

/// A 1x1 transparent PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

class _Fixed implements AvatarImages {
  const _Fixed(this.provider);
  final ImageProvider provider;
  @override
  ImageProvider? resolve(AvatarRef ref, double physicalSize) => provider;
}

Widget _withImage(ImageProvider provider) => AvatarImagesScope(
  images: _Fixed(provider),
  child: _host(
    LoafAvatar(
      label: 'AB',
      color: Colors.red,
      size: 36,
      textStyle: loafBody(13, 600),
      image: const AvatarRef('mxc://x/y'),
    ),
  ),
);

void main() {
  testWidgets('draws its label on its colour', (tester) async {
    await tester.pumpWidget(
      _host(
        LoafAvatar(
          label: 'AB',
          color: Colors.red,
          size: 36,
          textStyle: loafBody(13, 600),
        ),
      ),
    );
    expect(find.text('AB'), findsOneWidget);
    final decoration = _decoration(tester);
    expect(decoration.color, Colors.red);
    expect(decoration.shape, BoxShape.circle);
  });

  testWidgets('a radius makes a rounded square', (tester) async {
    await tester.pumpWidget(
      _host(
        LoafAvatar(
          label: 'AB',
          color: Colors.red,
          size: 36,
          radius: 10,
          textStyle: loafBody(13, 600),
        ),
      ),
    );
    final decoration = _decoration(tester);
    expect(decoration.borderRadius, BorderRadius.circular(10));
    expect(decoration.shape, BoxShape.rectangle);
  });

  testWidgets('is exactly its size', (tester) async {
    await tester.pumpWidget(
      _host(
        LoafAvatar(
          label: 'AB',
          color: Colors.red,
          size: 36,
          textStyle: loafBody(13, 600),
        ),
      ),
    );
    expect(tester.getSize(find.byType(LoafAvatar)), const Size(36, 36));
  });

  testWidgets('no scope draws initials only', (tester) async {
    await tester.pumpWidget(
      _host(
        LoafAvatar(
          label: 'AB',
          color: Colors.red,
          size: 36,
          textStyle: loafBody(13, 600),
          image: const AvatarRef('mxc://x/y'),
        ),
      ),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.text('AB'), findsOneWidget);
  });

  testWidgets('a resolved image draws over the initials', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(_withImage(MemoryImage(_png)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    // Decoded, so it really is painted: the failing case's contrast.
    expect(
      find.descendant(of: find.byType(Image), matching: find.byType(RawImage)),
      findsOneWidget,
    );
    expect(find.text('AB'), findsOneWidget);
    expect(tester.getSize(find.byType(LoafAvatar)), const Size(36, 36));
  });

  testWidgets('a failing image keeps the initials', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _withImage(MemoryImage(Uint8List.fromList([1, 2, 3]))),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text('AB'), findsOneWidget);
    // The error builder replaced the image: nothing is painted over the
    // label (a decoded picture would leave a RawImage here).
    expect(
      find.descendant(of: find.byType(Image), matching: find.byType(RawImage)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a border is drawn on the same decoration', (tester) async {
    final border = Border.all(color: Colors.blue, width: 2);
    await tester.pumpWidget(
      _host(
        LoafAvatar(
          label: 'AB',
          color: Colors.red,
          size: 36,
          textStyle: loafBody(13, 600),
          border: border,
        ),
      ),
    );
    expect(_decoration(tester).border, border);
  });
}
