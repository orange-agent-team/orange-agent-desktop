import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/desktop_connection.dart';
import 'package:orange_desktop/src/rust/api/host.dart';
import 'package:orange_desktop/src/rust/frb_generated.dart';

void main() {
  test('restores the local host after a missing library and an unavailable data directory', () async {
    final lib = Platform.environment['ORANGE_STARTUP_TEST_LIBRARY']!;
    final temp = await Directory.systemTemp.createTemp('orange-startup-test-');
    final data = Directory('${temp.path}/agent');
    final obstruction = await File(data.path).create();
    var loads = 0;
    HostView? opened;
    try {
      final connection = DesktopConnection(
        initializeBridge: () async {
          final path = ++loads == 1 ? '${temp.path}/missing-library' : lib;
          await RustLib.init(externalLibrary: ExternalLibrary.open(path));
        },
        openHost: () => initializeHost(applicationDataDirectory: data.path),
      );
      await expectLater(
        connection.connect(),
        throwsA(isA<BridgeStartupFailure>()),
      );
      expect(RustLib.instance.initialized, isFalse);
      await expectLater(connection.connect(), throwsA(isA<BridgeError>()));
      expect(RustLib.instance.initialized, isTrue);
      await obstruction.delete();
      // The native Host creates the missing journal directory with owner-only permissions.
      opened = await connection.connect();
      final observed = await inspectHost(handle: opened.handle);
      expect(observed.handle, opened.handle);
      expect(observed.availableReadTools, contains('read_file'));
      expect(loads, 2);
    } finally {
      if (opened != null) await closeHost(handle: opened.handle);
      if (RustLib.instance.initialized) RustLib.dispose();
      await temp.delete(recursive: true);
    }
  });
}
