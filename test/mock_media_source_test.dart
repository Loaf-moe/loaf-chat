import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/mock/fixtures.dart';
import 'package:loaf_native/ui/mock/mock_media_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late MockMediaSource source;
  const oven = Media(
    kind: MediaKind.image,
    name: 'oven.jpg',
    ref: 'assets/mock/media/oven.jpg',
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('loaf-mock-media-test');
    source = MockMediaSource(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('a sample opens complete, with its real name on disk', () async {
    final file = source.open(oven);
    final path = await file.path;
    expect(path, endsWith('/oven.jpg'));
    expect(File(path).existsSync(), isTrue);
    expect(file.complete, isTrue);
    expect(file.received, file.total);
    expect(file.received, File(path).lengthSync());
  });

  test('opening twice is one file', () {
    expect(identical(source.open(oven), source.open(oven)), isTrue);
  });
}
