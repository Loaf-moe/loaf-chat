import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/update/feed/release_feed.dart';
import 'package:loaf_native/update/feed/verified_asset.dart';

Release _release({int build = 2, int size = 1024}) => Release(
  version: '0.1.$build',
  build: build,
  assets: {
    AssetKind.appImage: ReleaseAsset(
      url: Uri.parse('https://example.org/app'),
      sha256: 'ab' * 32,
      size: size,
      signature: 'good',
    ),
  },
);

bool _good(String message, String signature) => signature == 'good';

void main() {
  test('a newer, signed build is verified', () {
    final asset = VerifiedAsset.check(
      _release(),
      AssetKind.appImage,
      _good,
      build: 1,
    );
    expect(asset?.version, '0.1.2');
    expect(asset?.asset.size, 1024);
  });

  test('the same or an older build is nothing to fetch', () {
    for (final build in [2, 3]) {
      expect(
        VerifiedAsset.check(
          _release(),
          AssetKind.appImage,
          _good,
          build: build,
        ),
        isNull,
      );
    }
  });

  test('a release with no build of the kind is nothing to fetch', () {
    expect(
      VerifiedAsset.check(_release(), AssetKind.windows, _good, build: 1),
      isNull,
    );
  });

  test('a signature the key did not make is refused', () {
    expect(
      () => VerifiedAsset.check(
        _release(),
        AssetKind.appImage,
        (_, _) => false,
        build: 1,
      ),
      throwsStateError,
    );
  });

  test('what the key signs names the kind and the hash', () {
    String? signed;
    VerifiedAsset.check(_release(), AssetKind.appImage, (message, _) {
      signed = message;
      return true;
    }, build: 1);
    expect(signed, 'loaf-chat-appimage\n0.1.2\n2\n${'ab' * 32}');
  });

  test('a build too big to be real is refused', () {
    expect(
      () => VerifiedAsset.check(
        _release(size: largestAsset + 1),
        AssetKind.appImage,
        _good,
        build: 1,
      ),
      throwsStateError,
    );
  });
}
