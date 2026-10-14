import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  const _Fixed(this.provider, {this.whole});
  final ImageProvider provider;
  final ImageProvider? whole;
  @override
  ImageProvider? resolve(AvatarRef ref, double physicalSize) => provider;
  @override
  ImageProvider? original(AvatarRef ref) => whole;
}

Widget _withImage(
  ImageProvider provider, {
  ImageProvider? whole,
  bool original = false,
}) => AvatarImagesScope(
  images: _Fixed(provider, whole: whole),
  child: _host(
    LoafAvatar(
      label: 'AB',
      color: Colors.red,
      size: 36,
      textStyle: loafBody(13, 600),
      image: const AvatarRef('mxc://x/y'),
      original: original,
    ),
  ),
);

/// Pumps [widget] and lets its images decode.
Future<void> _settle(WidgetTester tester, Widget widget) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(widget);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pumpAndSettle();
}

/// The picture's painter, there only once it has decoded.
final _painted = find.descendant(
  of: find.byType(AvatarPicture),
  matching: find.byType(CustomPaint),
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
    expect(find.byType(AvatarPicture), findsNothing);
    expect(find.text('AB'), findsOneWidget);
  });

  testWidgets('a resolved image draws over the initials', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(_withImage(MemoryImage(_png)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.byType(AvatarPicture), findsOneWidget);
    // Decoded, so it really is painted: the failing case's contrast.
    expect(_painted, findsOneWidget);
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
    // Nothing is painted over the label (a decoded picture would leave its
    // painter here).
    expect(_painted, findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('asked for the original', () {
    testWidgets('it draws over the thumbnail', (tester) async {
      await _settle(
        tester,
        _withImage(MemoryImage(_png), whole: MemoryImage(_png), original: true),
      );
      final pictures = tester
          .widgetList<AvatarPicture>(find.byType(AvatarPicture))
          .toList();
      expect(pictures, hasLength(2));
      expect(pictures.last.provider, MemoryImage(_png));
      expect(pictures.last.gapless, isTrue);
      expect(_painted, findsNWidgets(2));
    });

    testWidgets('with no original to give, the thumbnail stands alone', (
      tester,
    ) async {
      await _settle(tester, _withImage(MemoryImage(_png), original: true));
      expect(find.byType(AvatarPicture), findsOneWidget);
    });

    testWidgets('a failing original leaves the thumbnail painted', (
      tester,
    ) async {
      await _settle(
        tester,
        _withImage(
          MemoryImage(_png),
          whole: MemoryImage(Uint8List.fromList([1, 2, 3])),
          original: true,
        ),
      );
      expect(_painted, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a new original keeps the old one up until it arrives', (
      tester,
    ) async {
      Widget at(ImageProvider whole) =>
          _host(AvatarPicture(provider: whole, gapless: true));
      await _settle(tester, at(MemoryImage(_png)));
      expect(_painted, findsOneWidget);
      // Never decodes: a gapless picture still shows the last one.
      await tester.pumpWidget(at(MemoryImage(Uint8List.fromList([1, 2, 3]))));
      await tester.pump();
      expect(_painted, findsOneWidget);
    });

    testWidgets('not asked, the original is never resolved', (tester) async {
      await _settle(
        tester,
        _withImage(MemoryImage(_png), whole: MemoryImage(_png)),
      );
      expect(find.byType(AvatarPicture), findsOneWidget);
    });
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

  // A clip is a stencil on Impeller's GLES backend, hard-edged without MSAA
  // (Linux): the picture is the shape's own fill instead.
  for (final radius in [null, 10.0]) {
    testWidgets('the picture is not clipped (radius $radius)', (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          AvatarImagesScope(
            images: _Fixed(MemoryImage(_png)),
            child: _host(
              LoafAvatar(
                label: 'AB',
                color: Colors.red,
                size: 36,
                radius: radius,
                textStyle: loafBody(13, 600),
                image: const AvatarRef('mxc://x/y'),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(_painted, findsOneWidget);
      final avatar = find.byType(LoafAvatar);
      expect(
        find.descendant(of: avatar, matching: find.byType(ClipOval)),
        findsNothing,
      );
      expect(
        find.descendant(of: avatar, matching: find.byType(ClipRRect)),
        findsNothing,
      );
    });
  }

  testWidgets('the picture covers the circle, centred, and stays in it', (
    tester,
  ) async {
    // 8x4: red left, blue right. Covering a square crops it to its middle,
    // so each half of the avatar is one colour.
    final key = GlobalKey();
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = _red)
        ..drawRect(const Rect.fromLTWH(4, 0, 4, 4), Paint()..color = _blue);
      final source = await recorder.endRecording().toImage(8, 4);
      final png = await source.toByteData(format: ui.ImageByteFormat.png);
      source.dispose();
      await tester.pumpWidget(
        AvatarImagesScope(
          images: _Fixed(MemoryImage(png!.buffer.asUint8List())),
          child: _host(
            RepaintBoundary(
              key: key,
              child: LoafAvatar(
                label: '',
                color: Colors.transparent,
                size: 36,
                textStyle: loafBody(13, 600),
                image: const AvatarRef('mxc://x/y'),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    final pixels = await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData();
      image.dispose();
      return data!;
    });
    Color at(int x, int y) {
      final i = (y * 36 + x) * 4;
      return Color.fromARGB(
        pixels!.getUint8(i + 3),
        pixels.getUint8(i),
        pixels.getUint8(i + 1),
        pixels.getUint8(i + 2),
      );
    }

    expect(at(6, 18), _red);
    expect(at(29, 18), _blue);
    // The corners are outside the circle: nothing painted there.
    for (final (x, y) in [(1, 1), (34, 1), (1, 34), (34, 34)]) {
      expect(at(x, y).a, 0, reason: 'corner ($x, $y)');
    }
  });
}

const _red = Color(0xFFFF0000);
const _blue = Color(0xFF0000FF);
