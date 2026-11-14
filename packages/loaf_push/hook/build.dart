/// Builds the Rust crate `loaf_push` and bundles it, so Flutter embeds it
/// where each platform looks for it. On iOS that is the app's Frameworks,
/// which the Notification Service Extension `dlopen`s; everywhere else the
/// app itself calls it over FFI to judge the push rules. Android gets
/// nothing: there is no Android release.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) return;
  final code = input.config.code;
  final triple = _triple(code);
  if (triple == null) return;

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
      if (code.targetOS == OS.iOS)
        'IPHONEOS_DEPLOYMENT_TARGET': '${code.iOS.targetVersion}',
      if (code.targetOS == OS.macOS)
        'MACOSX_DEPLOYMENT_TARGET': '${code.macOS.targetVersion}',
      // Xcode's PATH puts its toolchain's bare cc first, which has no macOS
      // SDK, so cargo's build scripts (built for this Mac) fail to link.
      // /usr/bin/cc is the xcrun shim that finds the SDK.
      if (code.targetOS == OS.iOS || code.targetOS == OS.macOS)
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
      file: cargoDir.resolve('$triple/release/${_library(code.targetOS)}'),
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

/// The Rust target for what is being built, or null for an OS that gets no
/// library. An architecture this OS does build for, with no triple here, is
/// a mistake worth failing on rather than a silently missing library.
String? _triple(CodeConfig code) => switch (code.targetOS) {
  OS.iOS => switch ((code.targetArchitecture, code.iOS.targetSdk)) {
    (Architecture.arm64, IOSSdk.iPhoneOS) => 'aarch64-apple-ios',
    (Architecture.arm64, IOSSdk.iPhoneSimulator) => 'aarch64-apple-ios-sim',
    // Flutter builds the simulator for Intel too, and joins the two.
    (Architecture.x64, IOSSdk.iPhoneSimulator) => 'x86_64-apple-ios',
    final other => throw UnsupportedError(
      'loaf_push: no Rust target for $other',
    ),
  },
  // A release build of the Mac app is universal (the Runner project leaves
  // ONLY_ACTIVE_ARCH to Xcode outside Debug), so both arches are built.
  OS.macOS => switch (code.targetArchitecture) {
    Architecture.arm64 => 'aarch64-apple-darwin',
    Architecture.x64 => 'x86_64-apple-darwin',
    final other => throw UnsupportedError(
      'loaf_push: no Rust target for macOS $other',
    ),
  },
  OS.linux => switch (code.targetArchitecture) {
    Architecture.x64 => 'x86_64-unknown-linux-gnu',
    Architecture.arm64 => 'aarch64-unknown-linux-gnu',
    final other => throw UnsupportedError(
      'loaf_push: no Rust target for Linux $other',
    ),
  },
  OS.windows => switch (code.targetArchitecture) {
    Architecture.x64 => 'x86_64-pc-windows-msvc',
    Architecture.arm64 => 'aarch64-pc-windows-msvc',
    final other => throw UnsupportedError(
      'loaf_push: no Rust target for Windows $other',
    ),
  },
  _ => null,
};

String _library(OS os) => switch (os) {
  OS.windows => 'loaf_push.dll',
  OS.linux => 'libloaf_push.so',
  _ => 'libloaf_push.dylib',
};
