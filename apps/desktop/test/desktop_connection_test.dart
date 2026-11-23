import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/desktop_connection.dart';
import 'package:orange_desktop/main.dart';
import 'package:orange_desktop/src/rust/api/host.dart';

const host = HostView(
  handle: 'fixture',
  contractVersion: '1',
  runtimeVersion: '1',
  runtimeSourceCommit: 'test',
  availableReadTools: [],
  availableEditTools: [],
);

void main() {
  test('shares an in-flight load, retries a failed load and retains a ready bridge', () async {
    final load = Completer<void>();
    var loads = 0, opens = 0;
    final connection = DesktopConnection(
      initializeBridge: () async {
        if (++loads == 1) await load.future;
      },
      openHost: () async {
        if (++opens == 1) {
          throw const BridgeError(code: 'HOST_BUSY', correlationId: 'first');
        }
        return host;
      },
    );
    final first = connection.connect();
    expect(identical(first, connection.connect()), isTrue);
    final rejected = expectLater(first, throwsA(isA<BridgeStartupFailure>()));
    load.completeError(StateError('native load failed'));
    await rejected;
    expect(opens, 0);
    await expectLater(connection.connect(), throwsA(isA<BridgeError>()));
    expect(await connection.connect(), host);
    expect(loads, 2);
    expect(opens, 2);
  });

  testWidgets(
    'keyboard retry starts a fresh attempt and distinguishes journal contention',
    (tester) async {
      var loads = 0;
      final connection = DesktopConnection(
        initializeBridge: () async {
          if (++loads == 1) {
            throw StateError('private path must not be displayed');
          }
        },
        openHost: () async => throw const BridgeError(
          code: 'HOST_BUSY',
          correlationId: 'private',
        ),
      );
      await tester.pumpWidget(OrangeDesktopApp(connect: connection.connect));
      await tester.pumpAndSettle();
      expect(find.text('本地运行组件未能启动'), findsOneWidget);
      expect(find.textContaining('private'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('本地记录暂时无法打开'), findsOneWidget);
      expect(find.textContaining('其他 Orange Agent 进程'), findsOneWidget);
      expect(loads, 2);
      expect(find.byType(FilledButton), findsOneWidget);
    },
  );
}
