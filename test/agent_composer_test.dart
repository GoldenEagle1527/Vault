import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/screens/agent/widgets/agent_composer.dart';

void main() {
  testWidgets('composer exposes attach and send actions', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    var attachCount = 0;
    var sendCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentComposer(
            controller: controller,
            focusNode: focusNode,
            running: false,
            onAttach: () => attachCount++,
            onPaste: () {},
            onSend: () => sendCount++,
            onCancel: () {},
            profileSwitcher: const SizedBox.shrink(),
          ),
        ),
      ),
    );

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('继续描述你的需求…'), findsOneWidget);
    await tester.tap(find.byTooltip('添加文件'));
    await tester.tap(find.byTooltip('发送'));
    expect(attachCount, 1);
    expect(sendCount, 1);
  });

  testWidgets('running composer disables input and exposes stop', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    var cancelCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentComposer(
            controller: controller,
            focusNode: focusNode,
            running: true,
            onAttach: () {},
            onPaste: () {},
            onSend: () {},
            onCancel: () => cancelCount++,
            profileSwitcher: const SizedBox.shrink(),
          ),
        ),
      ),
    );

    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await tester.tap(find.byTooltip('停止'));
    expect(cancelCount, 1);
  });
}
