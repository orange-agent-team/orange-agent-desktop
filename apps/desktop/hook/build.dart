import 'dart:io';

import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final verifier = input.packageRoot.resolve(
      '../../scripts/import-runtime.py',
    );
    final lock = input.packageRoot.resolve('../../config/runtime.lock.json');
    final linkerConfig = input.packageRoot.resolve(
      '../../crates/desktop-bridge/build.rs',
    );
    output.dependencies.addAll([verifier, lock, linkerConfig]);
    final result = await Process.run('python3', [
      File.fromUri(verifier).path,
      '--verify',
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'Shared Runtime source verification failed: ${result.stderr}${result.stdout}',
      );
    }
    final fingerprintTool = input.packageRoot.resolve(
      '../../scripts/model-bundle-fingerprint.py',
    );
    final bundleManifest = input.packageRoot.resolve(
      '../../.local/model-bundle/manifest.json',
    );
    output.dependencies.addAll([
      fingerprintTool,
      input.packageRoot.resolve('../../scripts/model_bundle.py'),
    ]);
    if (await File.fromUri(bundleManifest).exists()) {
      output.dependencies.add(bundleManifest);
    }
    final fingerprint = await Process.run('python3', [
      File.fromUri(fingerprintTool).path,
    ]);
    final digest = (fingerprint.stdout as String).trim();
    if (fingerprint.exitCode != 0 ||
        !(digest == 'not-packaged' ||
            RegExp(r'^[0-9a-f]{64}$').hasMatch(digest))) {
      throw StateError('Model bundle fingerprint verification failed');
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: '../../crates/desktop-bridge',
      extraCargoBuildArgs: ['--locked'],
      extraCargoEnvironmentVariables: {'ORANGE_MODEL_BUNDLE_SHA256': digest},
    ).run(input: input, output: output);
  });
}
