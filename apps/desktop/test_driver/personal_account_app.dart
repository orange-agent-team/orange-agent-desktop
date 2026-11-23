// Native qualification entry point. The packaged PersonalAccountPanel runs with a fresh real Host.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:orange_desktop/personal_account_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart' as host;
import 'package:orange_desktop/src/rust/frb_generated.dart';

Future<void> main() async {
  final ready = Completer<void>();
  late Directory state;
  late host.HostView session;
  enableFlutterDriverExtension(
    handler: (message) async {
      await ready.future;
      if (message == 'wait-ready') {
        return 'ready';
      }
      if (message != 'close-fixture') {
        throw StateError('Unknown fixture action');
      }
      await host.closeHost(handle: session.handle);
      await state.delete(recursive: true);
      return 'closed';
    },
  );
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await RustLib.init();
    state = await Directory.systemTemp.createTemp('orange-account-test-');
    session = await host.initializeHost(
      applicationDataDirectory: await state.resolveSymbolicLinks(),
    );
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PersonalAccountPanel(handle: session.handle),
          ),
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    ready.complete();
  } catch (error, stack) {
    ready.completeError(error, stack);
    rethrow;
  }
}
