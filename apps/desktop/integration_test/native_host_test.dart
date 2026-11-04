import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:orange_desktop/main.dart';
import 'package:orange_desktop/src/rust/api/host.dart';
import 'package:orange_desktop/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => RustLib.init());
  testWidgets(
    'real native Host, integer transport and stale handle rejection',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'orange-native-host-',
      );
      String? openHandle;
      try {
        final platformData = await applicationDataDirectory();
        expect(platformData, isNotEmpty);
        final host = await initializeHost(
          applicationDataDirectory: directory.path,
        );
        openHandle = host.handle;
        expect(
          host.runtimeSourceCommit,
          '628cd5f3acb340c7349bfc8822f3f167e3020718',
        );
        expect(host.contractVersion, 'desktop-host.v1');
        expect(
          host.availableReadTools,
          unorderedEquals(['read_file', 'list_directory']),
        );
        final duplicate = await initializeHost(
          applicationDataDirectory: directory.path,
        );
        expect(duplicate.handle, host.handle);
        expect(
          await validateAmount(handle: host.handle, value: '9007199254740993'),
          '9007199254740993',
        );
        expect(
          await validateAmount(
            handle: host.handle,
            value: '9223372036854775807',
          ),
          '9223372036854775807',
        );
        for (final value in ['01', '-1', '1.5', '9223372036854775808']) {
          await expectLater(
            validateAmount(handle: host.handle, value: value),
            throwsA(
              isA<BridgeError>().having(
                (e) => e.code,
                'code',
                'INVALID_AMOUNT',
              ),
            ),
          );
        }
        await expectLater(
          initializeHost(applicationDataDirectory: 'relative-directory'),
          throwsA(
            isA<BridgeError>().having(
              (e) => e.code,
              'code',
              'INVALID_DATA_DIRECTORY',
            ),
          ),
        );
        await tester.pumpWidget(
          OrangeDesktopApp(
            connect: () async => inspectHost(handle: host.handle),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('本地记录已连接'), findsOneWidget);
        await closeHost(handle: host.handle);
        openHandle = null;
        await expectLater(
          inspectHost(handle: host.handle),
          throwsA(
            isA<BridgeError>().having(
              (e) => e.code,
              'code',
              'STALE_HOST_HANDLE',
            ),
          ),
        );
        final reopened = await initializeHost(
          applicationDataDirectory: directory.path,
        );
        openHandle = reopened.handle;
        expect(reopened.handle, isNot(host.handle));
        await expectLater(
          closeHost(handle: host.handle),
          throwsA(
            isA<BridgeError>().having(
              (e) => e.code,
              'code',
              'STALE_HOST_HANDLE',
            ),
          ),
        );
        expect(
          (await inspectHost(handle: reopened.handle)).handle,
          reopened.handle,
        );
      } finally {
        if (openHandle != null) await closeHost(handle: openHandle);
        await directory.delete(recursive: true);
      }
    },
  );
}
