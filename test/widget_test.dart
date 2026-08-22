import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/agent/vault_meta_db.dart';
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
  Future<SandboxWorkspace> create(
    String workspaceId, {
    WorkspaceInitProgressCallback? onProgress,
  }) {
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
  ) async => null;

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

  @override
  Future<String> resolveGuestHostPath(
    String workspaceId,
    String guestAbsolutePath,
  ) async => guestAbsolutePath;

  @override
  Future<CommandResult> runGuestCommand(String workspaceId, String cmd) async =>
      const CommandResult(exitCode: 0, stdout: '', stderr: '');

  @override
  Future<void> stopRunningGuests() async {}

  @override
  Future<List<GuestFsEntry>> listGuestDirectory(
    String workspaceId,
    String guestAbsolutePath,
  ) async => const [];
}

void main() {
  testWidgets('Vault 主页渲染欢迎区与空工作区状态', (tester) async {
    final temp = Directory.systemTemp.createTempSync('vault_widget_');
    final metaDb = VaultMetaDb.at(p.join(temp.path, 'vault_meta.db'));

    await tester.pumpWidget(
      VaultApp(
        provider: _FakeProvider(),
        themeController: ThemeController(),
        metaDb: metaDb,
      ),
    );
    // Flush async _refresh started from initState.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('工作区'), findsWidgets);
    expect(find.text('一个工作区 = 一套独立 Linux 环境'), findsOneWidget);
    expect(find.text('全部工作区'), findsOneWidget);
    expect(find.text('新建工作区'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });
}
