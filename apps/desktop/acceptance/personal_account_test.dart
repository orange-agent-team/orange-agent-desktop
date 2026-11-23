import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/personal_account_panel.dart';
import 'package:orange_desktop/src/rust/api/account.dart' as account;
import 'package:orange_desktop/src/rust/api/host.dart' as api;
import 'package:orange_desktop/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final environment = Platform.environment;
  final root = Directory(environment['ORANGE_TEST_ACCOUNT_DIRECTORY']!);
  final walletKey = environment['ORANGE_TEST_ACCOUNT_WALLET_KEY']!;
  final budgetKey = environment['ORANGE_TEST_ACCOUNT_BUDGET_KEY']!;
  final ca = File('${root.path}/ca.pem').readAsStringSync();
  late api.HostView host;
  var opened = false;
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        environment['ORANGE_TEST_ACCOUNT_LIBRARY']!,
      ),
    );
    final journal = Directory('${root.path}/host');
    try {
      host = await api.initializeHost(
        applicationDataDirectory: journal.resolveSymbolicLinksSync(),
      );
      opened = true;
    } on api.BridgeError catch (e) {
      throw StateError(
        'Private native test host refused initialization: ${e.code}',
      );
    }
  });
  tearDownAll(() async {
    if (opened) {
      await api.closeHost(handle: host.handle);
    }
    RustLib.dispose();
  });
  test('native bridge verifies TLS and returns scoped decimal wallet and budget pages', () async {
    final target = await account.personalApiEndpoint(handle: host.handle);
    expect(target.origin, 'https://127.0.0.1:43122');
    expect(target.allowLocalDevelopmentCertificate, isTrue);
    Future<void> denied(Future<Object?> future, String code) async {
      try {
        await future;
      } on api.BridgeError catch (e) {
        expect(e.code, code);
        return;
      }
      fail('Unexpected account read');
    }

    await denied(
      account.readPersonalWallet(handle: host.handle, credential: walletKey),
      'ACCOUNT_CONNECTION_FAILED',
    );
    await denied(
      account.readPersonalWallet(
        handle: host.handle,
        credential: budgetKey,
        localCertificatePem: ca,
      ),
      'ACCOUNT_SCOPE_DENIED',
    );
    final wallet = await account.readPersonalWallet(
      handle: host.handle,
      credential: walletKey,
      localCertificatePem: ca,
    );
    expect(wallet.ownerId, environment['ORANGE_TEST_ACCOUNT_OWNER']);
    expect(wallet.gift, '9007199254740993');
    final first = await account.readPersonalBudgets(
      handle: host.handle,
      credential: budgetKey,
      localCertificatePem: ca,
      limit: 1,
    );
    expect(first.ownerId, wallet.ownerId);
    expect(first.userId, wallet.userId);
    expect(first.data.single.limit, '9007199254740993');
    expect(first.nextCursor, first.data.single.rootBudgetId);
    final last = await account.readPersonalBudgets(
      handle: host.handle,
      credential: budgetKey,
      localCertificatePem: ca,
      limit: 1,
      after: first.nextCursor,
    );
    expect(last.data.single.rootBudgetId, isNot(first.nextCursor));
    expect(last.nextCursor, isNull);
    await denied(
      account.readPersonalBudgets(
        handle: host.handle,
        credential: budgetKey,
        localCertificatePem: ca,
        limit: 101,
      ),
      'ACCOUNT_CURSOR_INVALID',
    );
    File('${root.path}/read-complete').writeAsStringSync('ok');
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!File('${root.path}/revoked').existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Controller did not confirm revocation');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await denied(
      account.readPersonalWallet(
        handle: host.handle,
        credential: walletKey,
        localCertificatePem: ca,
      ),
      'ACCOUNT_KEY_INACTIVE',
    );
  });

  testWidgets(
    'desktop panel reads real budgets and clears its sensitive view when hidden',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PersonalAccountPanel(handle: host.handle),
            ),
          ),
        ),
      );
      await tester.tap(find.text('个人平台账户'));
      await tester.pump(const Duration(milliseconds: 300));
      Future<void> visible(Finder finder) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (finder.evaluate().isEmpty) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Expected account panel state did not arrive');
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await visible(find.text('本机开发证书'));
      await tester.ensureVisible(find.text('本机开发证书'));
      await tester.tap(find.text('本机开发证书'));
      await tester.pumpAndSettle();
      Finder input(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );
      await tester.enterText(input('公开 TLS 证书（PEM）'), ca);
      await tester.ensureVisible(input('个人只读密钥'));
      await tester.enterText(input('个人只读密钥'), budgetKey);
      await tester.ensureVisible(find.byType(DropdownButton<String>));
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('个人预算').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('读取账户'));
      await tester.tap(find.text('读取账户'));
      await visible(find.text('desktop-budget-one'));
      expect(find.text('desktop-budget-two'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('desktop-budget-one'), findsNothing);
      expect(
        tester.widget<TextField>(input('个人只读密钥')).controller!.text,
        isEmpty,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('desktop-budget-two'), findsNothing);
    },
  );
}
