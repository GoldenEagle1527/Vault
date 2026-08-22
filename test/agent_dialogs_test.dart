import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/screens/agent/agent_dialogs.dart';

void main() {
  testWidgets('leave confirmation returns selected action', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await confirmLeaveAgentWorkspace(
                context,
                message: '确认离开',
                hasRunningSites: true,
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('停止站点并离开'), findsOneWidget);
    await tester.tap(find.text('停止站点并离开'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('inbox collision can allocate a new name', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await resolveAgentInboxCollision(
                context,
                name: 'file.txt',
                taken: {'file.txt'},
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动重命名'));
    await tester.pumpAndSettle();
    expect(result, 'file-2.txt');
  });
}
