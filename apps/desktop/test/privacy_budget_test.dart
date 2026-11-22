import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orange_desktop/model_controller.dart';
import 'package:orange_desktop/model_panel.dart';
import 'package:orange_desktop/src/rust/api/host.dart';

void main() {
  testWidgets('resource choices leave an uninstalled local-only model idle', (
    tester,
  ) async {
    final controller = ModelController('private-fixture', beforeStop: () {});
    controller.publish(
      const ModelServiceView(
        phase: 'idle',
        modelName: 'approved fixture',
        modelBytes: '491400032',
        installed: false,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ModelPanel(controller: controller),
          ),
        ),
      ),
    );
    expect(find.textContaining('平台算力费用为 0'), findsOneWidget);
    expect(find.text('下载审核模型'), findsOneWidget);
    expect(find.text('导入模型文件'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '启动本地模型'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('本机资源不足时的选择'));
    await tester.pumpAndSettle();
    expect(find.textContaining('在用户 Web 重新选择可发送的内容和付款预算'), findsOneWidget);
    expect(find.textContaining('桌面工作区文件和会话文本留在本机'), findsOneWidget);
    await tester.tap(find.text('本机资源不足时的选择'));
    await tester.pumpAndSettle();
    expect(controller.view!.phase, 'idle');
    expect(controller.view!.installed, isFalse);
    expect(controller.busy, isFalse);
    expect(controller.startUnconfirmed, isFalse);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
