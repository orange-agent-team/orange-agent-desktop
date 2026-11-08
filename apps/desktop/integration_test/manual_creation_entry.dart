// Explicit QA entry point only. Never used by the production lib/main.dart build.
// The native chooser remains real; only model protocol responses are fixtures.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:orange_desktop/main.dart' as product;
import 'package:orange_desktop/src/rust/api/host.dart';
import 'package:orange_desktop/src/rust/frb_generated.dart';

import 'local_model_fixture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const sentinel = String.fromEnvironment('ORANGE_QA_CREATION_SENTINEL');
  if (!sentinel.startsWith('ORANGE_QA_') || sentinel.length > 128) {
    throw StateError('Explicit bounded owned QA sentinel required');
  }
  await RustLib.init();
  final root = Directory(await product.applicationDataDirectory());
  final host = await initializeHost(applicationDataDirectory: root.path);
  final fixture = await LocalModelFixture.start(
    root,
    sentinel,
    createAfterRead: true,
  );
  runApp(
    product.OrangeDesktopApp(
      connect: () async => host,
      modelServiceDirectory: () async => fixture.root.path,
    ),
  );
}
