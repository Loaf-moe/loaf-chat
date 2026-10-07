import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/update/pick_updater.dart';

UpdaterKind _choose({
  bool release = true,
  int build = 412,
  TargetPlatform platform = TargetPlatform.linux,
  Map<String, String> environment = const {},
  bool installedBySetup = false,
}) => chooseUpdater(
  release: release,
  build: build,
  platform: platform,
  environment: environment,
  installedBySetup: installedBySetup,
);

const _flatpak = {'FLATPAK_ID': 'moe.loaf.chat'};
const _appImage = {'APPIMAGE': '/home/me/Loaf-Chat.AppImage'};

void main() {
  test('macOS uses Sparkle', () {
    expect(_choose(platform: TargetPlatform.macOS), UpdaterKind.sparkle);
  });

  test('inside a Flatpak, the portal', () {
    expect(_choose(environment: _flatpak), UpdaterKind.flatpak);
  });

  test('inside an AppImage, our own', () {
    expect(_choose(environment: _appImage), UpdaterKind.appImage);
  });

  test('an AppImage started from inside a Flatpak is still a Flatpak', () {
    expect(
      _choose(environment: {..._flatpak, ..._appImage}),
      UpdaterKind.flatpak,
    );
  });

  test('a bare Linux binary has none', () {
    expect(_choose(), UpdaterKind.none);
    expect(_choose(environment: {'APPIMAGE': ''}), UpdaterKind.none);
  });

  test('a Windows install from Setup updates itself', () {
    expect(
      _choose(platform: TargetPlatform.windows, installedBySetup: true),
      UpdaterKind.windows,
    );
  });

  test('a Windows build run from where it was built has none', () {
    // Swapping files under a developer's build folder would be a surprise.
    expect(_choose(platform: TargetPlatform.windows), UpdaterKind.none);
  });

  test('phones never', () {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      expect(_choose(platform: platform), UpdaterKind.none);
    }
  });

  test('a debug or profile build has none, wherever it runs', () {
    expect(
      _choose(release: false, platform: TargetPlatform.macOS),
      UpdaterKind.none,
    );
    expect(_choose(release: false, environment: _appImage), UpdaterKind.none);
  });

  test('a release build made by hand has none', () {
    // No build number means it did not come from the pipeline. With an
    // updater it would see every published build as newer than itself.
    expect(_choose(build: 0, platform: TargetPlatform.macOS), UpdaterKind.none);
    expect(_choose(build: 0, environment: _appImage), UpdaterKind.none);
    expect(_choose(build: 0, environment: _flatpak), UpdaterKind.none);
    expect(
      _choose(
        build: 0,
        platform: TargetPlatform.windows,
        installedBySetup: true,
      ),
      UpdaterKind.none,
    );
  });
}
