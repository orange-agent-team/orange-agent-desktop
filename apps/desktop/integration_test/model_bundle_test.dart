import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'packaged inherited-sandbox helpers execute and reject an unauthenticated parent before model effects',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('模型组件验证'))),
      );
      final environment = await const MethodChannel('orange_agent/platform')
          .invokeMapMethod<String, dynamic>('modelServiceEnvironment');
      expect(environment, isNotNull);
      final contents = environment!['contentsDirectory'] as String;
      final manifest = jsonDecode(
        await File('$contents/Resources/OrangeModelService/manifest.json')
            .readAsString(),
      ) as Map<String, dynamic>;
      expect(manifest['development_only'], isTrue);
      expect(manifest['cpu_only'], isTrue);
      final required = (manifest['minimum_macos'] as String)
          .split('.')
          .map(int.parse)
          .toList();
      final actual = (environment['osVersion'] as String)
          .split('.')
          .map(int.parse)
          .toList();
      expect(
        actual[0] > required[0] ||
            (actual[0] == required[0] && actual[1] >= required[1]),
        isTrue,
      );
      final backend = await Process.run('$contents/Helpers/llama-server', [
        '--version',
      ]).timeout(const Duration(seconds: 10));
      expect(backend.exitCode, 0);
      expect(
        '${backend.stdout}${backend.stderr}'.toLowerCase(),
        contains('version'),
      );
      final temporary = await Directory.systemTemp.createTemp('oh');
      Process? child;
      try {
        final root = await temporary.resolveSymbolicLinks();
        final profile = File('$root/profile.json');
        await profile.writeAsString(
          jsonEncode({
            'protocol': 1,
            'runtime_directory': root,
            'executable': '$contents/Helpers/llama-server',
            'executable_sha256': manifest['files']['llama-server']['sha256'],
            'model': '$root/intentionally-not-installed.gguf',
            'model_sha256': manifest['model']['sha256'],
            'model_bytes': manifest['model']['bytes'],
            'model_version': 'packaged-parent-fixture',
            'context_tokens': 4096,
            'startup_timeout_seconds': 5,
            'control_nonce': '1' * 64,
            'instance_id': 'packaged-parent-fixture-instance',
          }),
        );
        final chmod = await Process.run('/bin/chmod', ['600', profile.path]);
        expect(chmod.exitCode, 0);
        child = await Process.start('$contents/Helpers/orange-model-host', [
          profile.path,
        ]);
        final output = utf8.decoder.bind(child.stdout).join();
        final errors = utf8.decoder.bind(child.stderr).join();
        child.stdin.writeln('auth ${'2' * 64}');
        await child.stdin.flush();
        await child.stdin.close();
        final status = await child.exitCode.timeout(
          const Duration(seconds: 10),
        );
        expect(status, isNot(0));
        expect(await output, isEmpty);
        expect(await errors, contains('private control authentication failed'));
        expect(await File('$root/process.json').exists(), isFalse);
        expect(await File('$root/api.key').exists(), isFalse);
        expect(await File('$root/engine.lease').exists(), isFalse);
        debugPrint(
          jsonEncode({
            'packagedHelperProbe': true,
            'backendVersionExecuted': true,
            'parentAuthenticationRejected': true,
            'modelStarted': false,
            'minimumMacos': manifest['minimum_macos'],
          }),
        );
      } finally {
        if (child != null) {
          await child.stdin.close();
          await child.exitCode.timeout(const Duration(seconds: 10));
        }
        await temporary.delete(recursive: true);
      }
    },
  );
}
