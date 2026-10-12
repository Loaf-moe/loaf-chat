/// Builds the Rust crate `loaf_notify_win` as a DLL on Windows and bundles
/// it as the code asset `loaf_notify_win.dart`. Every other OS has no
/// native end here, so it adds nothing.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) => build(args, (input, output) async {
  if (!input.config.buildCodeAssets) return;
  if (input.config.code.targetOS != OS.windows) return;

  final crate = input.packageRoot.resolve('rust/');
  final cargoDir = input.outputDirectoryShared.resolve('cargo/');
  final cargo = await Process.run('cargo', [
    'build',
    '--release',
    '--locked',
    '--manifest-path',
    crate.resolve('Cargo.toml').toFilePath(),
    '--target-dir',
    cargoDir.toFilePath(),
  ]);
  if (cargo.exitCode != 0) {
    throw Exception('cargo build of loaf_notify_win failed:\n'
        '${cargo.stdout}\n${cargo.stderr}');
  }

  output.assets.code.add(
    CodeAsset(
      package: 'loaf_notify',
      name: 'loaf_notify_win.dart',
      linkMode: DynamicLoadingBundled(),
      file: cargoDir.resolve('release/loaf_notify_win.dll'),
    ),
  );
  // A changed Rust source, manifest or lockfile rebuilds the DLL.
  output.dependencies.addAll([
    crate.resolve('Cargo.toml'),
    crate.resolve('Cargo.lock'),
    for (final f in Directory.fromUri(crate.resolve('src/')).listSync())
      if (f is File) f.uri,
  ]);
});
