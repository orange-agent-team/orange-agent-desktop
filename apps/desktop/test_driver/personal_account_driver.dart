import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

Future<void> main() async {
  final dir = Directory(Platform.environment['ORANGE_TEST_ACCOUNT_DIRECTORY']!);
  final file = File('${dir.path}/driver-input.json');
  final fixture = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  await file.delete();
  final ca = await File('${dir.path}/ca.pem').readAsString();
  final d = await FlutterDriver.connect(
    printCommunication: false,
    logCommunicationToFile: false,
  );
  const wait = Duration(seconds: 20);
  Future<void> tap(SerializableFinder finder) async {
    await d.scrollIntoView(finder, alignment: .5, timeout: wait);
    await d.tap(finder, timeout: wait);
  }

  Future<void> type(String field, String value) async {
    await tap(find.byValueKey(field));
    await d.enterText(value, timeout: wait);
  }

  try {
    await tap(find.text('个人平台账户'));
    await tap(find.text('本机开发证书'));
    await type('personal-account-ca', ca);
    await type('personal-account-key', fixture['wallet'] as String);
    await tap(find.text('读取账户'));
    final amount = find.text('可用（微积分）　赠送 9007199254740993 · 收益 0 · 购买 0');
    await d.waitFor(amount, timeout: wait);
    await File('${dir.path}/read-complete').writeAsString('ok');
    final deadline = DateTime.now().add(wait);
    while (!await File('${dir.path}/revoked').exists()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Withdrawal unconfirmed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    await tap(find.text('读取账户'));
    await d.waitFor(find.text('密钥已失效，请在用户 Web 核对有效期或重新登记。'), timeout: wait);
    await d.waitForAbsent(amount, timeout: wait);
    await type('personal-account-key', fixture['budgets'] as String);
    await tap(find.byValueKey('personal-account-scope'));
    await d.tap(find.text('个人预算'), timeout: wait);
    await tap(find.text('读取账户'));
    await d.waitFor(find.text('desktop-budget-one'), timeout: wait);
    await d.waitFor(find.text('desktop-budget-two'), timeout: wait);
    await tap(find.text('清除密钥和结果'));
    await d.waitForAbsent(find.text('desktop-budget-one'), timeout: wait);
    stdout.writeln('NATIVE_ACCOUNT_WINDOW_CONFIRMED');
  } finally {
    try {
      await d.requestData('close-fixture', timeout: wait);
    } finally {
      await d.close();
    }
  }
}
