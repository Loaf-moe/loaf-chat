import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_media/loaf_media.dart';
import 'package:loaf_native/matrix/media_images.dart';

/// A 1×1 PNG, which Flutter's own codecs read.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
  0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
  0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

/// What a HEIC is to Flutter: bytes it has no codec for.
final _heic = Uint8List.fromList(List.filled(64, 7));

Future<ui.Codec> _flutter(
  ui.ImmutableBuffer buffer, {
  ui.TargetImageSizeCallback? getTargetSize,
}) => ui.instantiateImageCodecWithSize(buffer, getTargetSize: getTargetSize);

void main() {
  final asked = <(int, int?)>[];
  Future<DecodedImage> wic(Uint8List bytes, {int? maxWidth}) async {
    asked.add((bytes.length, maxWidth));
    // A 2×1 picture: one red pixel, one blue.
    return DecodedImage(
      2,
      1,
      Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255]),
    );
  }

  setUp(asked.clear);

  test('what Flutter reads never reaches WIC', () async {
    final codec = await decodeWithFallback(
      _png,
      _flutter,
      windows: true,
      wic: wic,
    );
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 1);
    expect(asked, isEmpty);
  });

  test(
    'on Windows, what Flutter refuses WIC decodes, at the row\'s width',
    () async {
      final codec = await decodeWithFallback(
        _heic,
        _flutter,
        width: 320,
        windows: true,
        wic: wic,
      );
      final frame = await codec.getNextFrame();
      expect((frame.image.width, frame.image.height), (2, 1));
      expect(asked, [(64, 320)]);
    },
  );

  test('elsewhere, what Flutter refuses fails as it did', () async {
    await expectLater(
      decodeWithFallback(_heic, _flutter, windows: false, wic: wic),
      throwsA(anything),
    );
    expect(asked, isEmpty);
  });

  test('when WIC can\'t either, the row fails, once', () async {
    Future<DecodedImage> refuse(Uint8List bytes, {int? maxWidth}) async {
      asked.add((bytes.length, maxWidth));
      throw StateError('no HEIF extension');
    }

    await expectLater(
      decodeWithFallback(_heic, _flutter, windows: true, wic: refuse),
      throwsA(anything),
    );
    expect(asked, hasLength(1));
  });
}
