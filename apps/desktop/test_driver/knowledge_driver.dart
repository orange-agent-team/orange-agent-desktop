import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

Future<void> main() async {
  final driver = await FlutterDriver.connect(
    printCommunication: false,
    logCommunicationToFile: false,
  );
  const wait = Duration(seconds: 25);
  Future<void> tap(SerializableFinder f) async {
    await driver.scrollIntoView(f, alignment: .5, timeout: wait);
    await driver.tap(f, timeout: wait);
  }

  Future<void> type(String key, String value) async {
    await tap(find.byValueKey(key));
    await driver.enterText(value, timeout: wait);
  }

  var live = false;
  try {
    final workspace = await driver.requestData('ready', timeout: wait);
    live = true;
    await tap(find.text('本地文档检索'));
    await tap(find.text('检索工作区'));
    await tap(find.byValueKey('knowledge-option-$workspace'));
    await type('knowledge-files', 'shipping.txt');
    await tap(find.text('在本机保存索引'));
    await type('knowledge-saved-name', 'harbor-manual');
    await tap(find.text('启用所选文档'));
    await tap(find.text('关闭文档集合'));
    await tap(find.text('查看已保存的集合'));
    await tap(find.byType('ActionChip'));
    await tap(find.text('启用所选文档'));
    await type('knowledge-query', 'harbor');
    await tap(find.text('检索所选文档'));
    await tap(
      find.descendant(
        of: find.byType('ListTile'),
        matching: find.text('shipping.txt'),
      ),
    );
    await driver.waitFor(
      find.text('First authorized harbor passage.'),
      timeout: wait,
    );
    await driver.waitForAbsent(
      find.text('Hidden harbor passage.'),
      timeout: wait,
    );
    await driver.requestData('remove-source', timeout: wait);
    await driver.waitFor(find.text('来源已变化，请重新检索。'), timeout: wait);
    await driver.waitForAbsent(
      find.text('First authorized harbor passage.'),
      timeout: wait,
    );
    await driver.requestData('restore-source', timeout: wait);
    await tap(find.text('检索所选文档'));
    await tap(
      find.descendant(
        of: find.byType('ListTile'),
        matching: find.text('shipping.txt'),
      ),
    );
    await driver.waitFor(
      find.text('Second authorized harbor passage.'),
      timeout: wait,
    );
    await tap(find.text('撤销已保存的集合'));
    await tap(find.text('取消撤销'));
    await driver.waitFor(
      find.text('Second authorized harbor passage.'),
      timeout: wait,
    );
    await tap(find.text('撤销已保存的集合'));
    await tap(find.text('确认撤销集合'));
    await driver.waitFor(find.text('已撤销集合「harbor-manual」。'), timeout: wait);
    await driver.waitForAbsent(
      find.text('Second authorized harbor passage.'),
      timeout: wait,
    );
    await type('knowledge-saved-name', 'harbor-manual');
    await tap(find.text('启用所选文档'));
    await driver.waitFor(find.text('此名称已撤销，请使用新名称。'), timeout: wait);
    // Qualify the independent workspace withdrawal against another, still-active saved index.
    await type('knowledge-saved-name', 'current-harbor');
    await tap(find.text('启用所选文档'));
    await type('knowledge-query', 'harbor');
    await tap(find.text('检索所选文档'));
    await tap(
      find.descendant(
        of: find.byType('ListTile'),
        matching: find.text('shipping.txt'),
      ),
    );
    await driver.waitFor(
      find.text('Second authorized harbor passage.'),
      timeout: wait,
    );
    await driver.requestData('revoke-workspace', timeout: wait);
    await driver.waitFor(find.text('工作区授权已失效，请重新选择。'), timeout: wait);
    await driver.waitForAbsent(
      find.text('Second authorized harbor passage.'),
      timeout: wait,
    );
    stdout.writeln('NATIVE_KNOWLEDGE_WINDOW_CONFIRMED');
  } finally {
    try {
      if (live) await driver.requestData('close-fixture', timeout: wait);
    } finally {
      await driver.close();
    }
  }
}
