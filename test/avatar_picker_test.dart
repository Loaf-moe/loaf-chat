import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/settings/avatar_picker.dart';

Future<Uint8List> _png(int w, int h) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFE8A0BF),
  );
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<(int, int)> _size(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  return (frame.image.width, frame.image.height);
}

void main() {
  // Image codecs are real async work, which the test clock would starve.
  testWidgets('a large picture shrinks to 512 on its long side', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final out = await shrinkToPng(await _png(1024, 600));
      expect(await _size(out), (512, 300));
    });
  });

  testWidgets('a tall picture shrinks on its height', (tester) async {
    await tester.runAsync(() async {
      final out = await shrinkToPng(await _png(600, 1024));
      expect(await _size(out), (300, 512));
    });
  });

  testWidgets('a small picture keeps its size', (tester) async {
    await tester.runAsync(() async {
      final out = await shrinkToPng(await _png(100, 80));
      expect(await _size(out), (100, 80));
    });
  });
}
