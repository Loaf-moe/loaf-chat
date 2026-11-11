import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/notify/toast_image.dart';

void main() {
  test('a picture is named by its first bytes', () {
    List<int> b(List<int> head) => [...head, ...List.filled(12, 0)];
    final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    final riff = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0];
    const webp = [0x57, 0x45, 0x42, 0x50];
    expect(toastImageExtension(b(png)), 'png');
    expect(toastImageExtension(b([0xFF, 0xD8, 0xFF, 0xE0])), 'jpg');
    expect(toastImageExtension(b('GIF89a'.codeUnits)), 'gif');
    expect(toastImageExtension(b([...riff, ...webp])), 'webp');
  });

  test('anything a toast cannot show has no extension', () {
    final riff = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0];
    expect(toastImageExtension([...riff, ...'AVI '.codeUnits]), isNull);
    expect(toastImageExtension('%PDF-1.7'.codeUnits), isNull);
    expect(
      toastImageExtension([0x89, 0x50]),
      isNull,
      reason: 'png needs all 8',
    );
    expect(toastImageExtension(const []), isNull);
  });
}
