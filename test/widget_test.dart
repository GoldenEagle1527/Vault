import 'dart:typed_data';

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
  Future<SandboxWorkspace> create(String workspaceId) {
    throw UnimplementedError();
  }

  @override
  Future<SandboxWorkspace> attach(String workspaceId) {
    throw UnimplementedError();
  }

  @override
  Future<void> destroy(String workspaceId) async {}

  @override
  Future<List<WorkspaceInfo>> list() async => const [];

  @override
  Future<Uint8List?> readGuestFile(
    String workspaceId,
    String guestAbsolutePath,
  ) async =>
      null;

  @override
  Future<void> writeGuestFile(
    String workspaceId,
    String guestAbsolutePath,
    List<int> bytes,
  ) async {}

  @override
  Future<void> deleteGuestPath(
    String workspaceId,
    String guestAbsolutePath, {
    bool recursive = false,
  }) async {}
}

void main() {
  testWidgets('Vault 主页渲染欢迎区与空工作区状态', (tester) async {
    await tester.pumpWidget(
      VaultApp(provider: _FakeProvider(), themeController: ThemeController()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Vault'), findsWidgets);
    expect(find.textContaining('今天想让 Vault 帮你做什么'), findsOneWidget);
    expect(find.textContaining('环境不可用'), findsWidgets);
    expect(find.textContaining('还没有工作区'), findsOneWidget);
    expect(find.text('新建工作区'), findsOneWidget);
  });
}
