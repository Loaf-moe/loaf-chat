/// Builds the Rust crate `loaf_push` for iOS and bundles it, so Flutter
/// embeds it in the app's Frameworks. No Dart calls it: the Notification
/// Service Extension dlopens it from there. Every other OS gets nothing.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) return;
  final code = input.config.code;
  if (code.targetOS != OS.iOS) return;

  final triple = switch ((code.targetArchitecture, code.iOS.targetSdk)) {
    (Architecture.arm64, IOSSdk.iPhoneOS) => 'aarch64-apple-ios',
    (Architecture.arm64, IOSSdk.iPhoneSimulator) => 'aarch64-apple-ios-sim',
    // Flutter builds the simulator for Intel too, and joins the two.
    (Architecture.x64, IOSSdk.iPhoneSimulator) => 'x86_64-apple-ios',
    final other => throw UnsupportedError(
      'loaf_push: no Rust target for $other',
    ),
  };
  final crate = input.packageRoot.resolve('rust/');
  final cargoDir = input.outputDirectoryShared.resolve('cargo/');
  final cargo = await Process.run(
    'cargo',
    [
      'build',
      '--release',
      '--locked',
      '--target',
      triple,
      '--manifest-path',
      crate.resolve('Cargo.toml').toFilePath(),
      '--target-dir',
      cargoDir.toFilePath(),
    ],
    environment: {
      'IPHONEOS_DEPLOYMENT_TARGET': '${code.iOS.targetVersion}',
      // Xcode's PATH puts its toolchain's bare cc first, which has no macOS
      // SDK, so cargo's build scripts (built for this Mac) fail to link.
      // /usr/bin/cc is the xcrun shim that finds the SDK.
      'PATH': '/usr/bin:${Platform.environment['PATH'] ?? ''}',
    },
    // rustup reads rust-toolchain.toml from here.
    workingDirectory: crate.toFilePath(),
  );
  if (cargo.exitCode != 0) {
    throw Exception(
      'cargo build of loaf_push failed:\n${cargo.stdout}\n${cargo.stderr}',
    );
  }

  output.assets.code.add(
    CodeAsset(
      package: 'loaf_push',
      name: 'loaf_push.dart',
      linkMode: DynamicLoadingBundled(),
      file: cargoDir.resolve('$triple/release/libloaf_push.dylib'),
    ),
  );
  // A changed Rust source, manifest or lockfile rebuilds the library.
  output.dependencies.addAll([
    crate.resolve('Cargo.toml'),
    crate.resolve('Cargo.lock'),
    for (final f in Directory.fromUri(crate.resolve('src/')).listSync())
      if (f is File) f.uri,
  ]);
});
