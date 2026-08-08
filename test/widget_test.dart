import 'package:flutter_test/flutter_test.dart';
import 'package:vault/main.dart';
import 'package:vault/sandbox/sandbox_provider.dart';

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
  testWidgets('Vault 主页渲染能力卡片', (tester) async {
    await tester.pumpWidget(VaultApp(provider: _FakeProvider()));
    await tester.pumpAndSettle();
    expect(find.text('Vault'), findsOneWidget);
    expect(find.textContaining('沙箱不可用'), findsOneWidget);
    expect(find.text('暂无会话。'), findsOneWidget);
  });
}
