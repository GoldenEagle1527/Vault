import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_site_controller.dart';
import 'package:vault/sandbox/sandbox_provider.dart';

class _FakeWorkspace implements SandboxWorkspace {
  @override
  String get workspaceId => 'workspace';

  @override
  Stream<Uint8List> get output => const Stream.empty();

  @override
  Future<int> get exitCode async => 0;

  @override
  void resize(int cols, int rows) {}

  @override
  Future<CommandResult> run(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  void write(String data) {}

  @override
  void writeBytes(Uint8List data) {}

  @override
  Future<void> writeGuestFile(
    String guestAbsolutePath,
    List<int> bytes,
  ) async {}

  @override
  Future<Uint8List?> readGuestFile(String guestAbsolutePath) async => null;

  @override
  Future<void> dispose() async {}
}

void main() {
  test('refresh clears stale status when no project has a site', () async {
    var changed = 0;
    final controller = AgentSiteController(
      workspace: _FakeWorkspace(),
      projects: () => const [],
      isMounted: () => true,
      onChanged: () => changed++,
      publicUrl: (entry) => entry.url,
      beforeStart: (_) async {},
      syncKeepAlive: (_) async {},
      onMessage: (_) {},
    );
    controller.siteUp['old-project'] = true;

    await controller.refreshStatus();

    expect(controller.siteUp, isEmpty);
    expect(changed, 1);
    expect(controller.probeGuard.inFlight, isFalse);
    controller.dispose();
  });
}
