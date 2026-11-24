// The real product shell receives one owned development workspace. Driver actions never return file contents.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:orange_desktop/main.dart' show OrangeDesktopApp;
import 'package:orange_desktop/src/rust/api/host.dart' as host;
import 'package:orange_desktop/src/rust/frb_generated.dart';

Future<void> main() async {
  final ready = Completer<void>();
  late Directory state;
  late host.HostView session;
  late host.WorkspaceView space;
  late File doc;
  enableFlutterDriverExtension(
    handler: (message) async {
      await ready.future;
      switch (message) {
        case 'ready':
          return space.workspaceId;
        case 'remove-source':
          await doc.delete();
          return 'removed';
        case 'restore-source':
          await doc.writeAsString('Second authorized harbor passage.');
          return 'restored';
        case 'revoke-workspace':
          await host.revokeWorkspace(
            handle: session.handle,
            workspaceId: space.workspaceId,
            expectedVersion: space.permissionVersion,
          );
          return 'revoked';
        case 'close-fixture':
          await host.closeHost(handle: session.handle);
          await state.delete(recursive: true);
          return 'closed';
        default:
          throw StateError('Unknown driver action');
      }
    },
  );
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await RustLib.init();
    state = await Directory.systemTemp.createTemp('orange-knowledge-app-');
    final root = await Directory('${state.path}/docs').create();
    doc = File('${root.path}/shipping.txt');
    await doc.writeAsString('First authorized harbor passage.');
    await File('${root.path}/unselected.txt')
        .writeAsString('Hidden harbor passage.');
    session = await host.initializeHost(
      applicationDataDirectory: '${state.resolveSymbolicLinksSync()}/private',
    );
    space = await host.authorizeWorkspace(
      handle: session.handle,
      requestId: 'native-knowledge-test',
      selectedDirectory: root.resolveSymbolicLinksSync(),
    );
    runApp(
      OrangeDesktopApp(
        connect: () async => session,
        modelServiceDirectory: () async => '${state.path}/model',
      ),
    );
    ready.complete();
  } catch (error, stack) {
    ready.completeError(error, stack);
    rethrow;
  }
}
