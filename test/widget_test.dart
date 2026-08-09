import 'package:flutter_test/flutter_test.dart';
import 'package:vault/main.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/theme/theme_controller.dart';

class _FakeProvider implements SandboxProvider {
  @override
  Future<SandboxCapabilities> probe() async {
    return const SandboxCapabilities(
      available: false,
      backend: SandboxBackend.unsupported,
      architecture: 'test',
      hint: '测试替身',
    );
  }

  @override
  Future<SandboxSession> create(String sessionId) {
    throw UnimplementedError();
  }

  @override
  Future<SandboxSession> attach(String sessionId) {
    throw UnimplementedError();
  }

  @override
  Future<void> destroy(String sessionId) async {}

  @override
  Future<List<SandboxInfo>> list() async => const [];
}

void main() {
  testWidgets('Vault 主页渲染欢迎区与空任务状态', (tester) async {
    await tester.pumpWidget(
      VaultApp(provider: _FakeProvider(), themeController: ThemeController()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Vault'), findsWidgets);
    expect(find.textContaining('今天想让 Vault 帮你做什么'), findsOneWidget);
    expect(find.textContaining('环境不可用'), findsWidgets);
    expect(find.textContaining('还没有任务'), findsOneWidget);
    expect(find.text('新建任务'), findsOneWidget);
  });
}
