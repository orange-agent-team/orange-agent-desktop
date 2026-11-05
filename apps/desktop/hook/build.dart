import 'dart:io';

import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final verifier = input.packageRoot.resolve(
      '../../scripts/import-runtime.py',
    );
    final lock = input.packageRoot.resolve('../../config/runtime.lock.json');
    output.dependencies.addAll([verifier, lock]);
    final result = await Process.run('python3', [
      File.fromUri(verifier).path,
      '--verify',
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'Shared Runtime source verification failed: ${result.stderr}${result.stdout}',
      );
    }
    await const FlutterRustBridgeNativeAssetsBuilder(
      cratePath: '../../crates/desktop-bridge',
      extraCargoBuildArgs: ['--locked'],
    ).run(input: input, output: output);
  });
}
