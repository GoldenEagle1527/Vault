import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/diagnostics/vault_api_smoke.dart';
import 'package:vault/permissions/offload_permission_manager.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/screens/settings/settings_coordinators.dart';

class _DelayedPermissionManager extends OffloadPermissionManager {
  final loadCompleter = Completer<void>();

  @override
  Future<void> ensureLoaded() => loadCompleter.future;
}

class _TestWorkspace implements SandboxWorkspace {
  bool disposed = false;

  @override
  String get workspaceId => 'dispose-test';

  @override
  Stream<Uint8List> get output => const Stream.empty();

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  void resize(int cols, int rows) {}

  @override
  Future<CommandResult> run(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async => const CommandResult(exitCode: 0, stdout: '', stderr: '');

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
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  test('permission load completing after dispose does not notify', () async {
    final manager = _DelayedPermissionManager();
    final coordinator = PermissionSettingsCoordinator(manager);
    var notifications = 0;
    coordinator.addListener(() => notifications++);

    final load = coordinator.load();
    coordinator.dispose();
    manager.loadCompleter.complete();

    await load;
    expect(notifications, 0);
    expect(coordinator.ready, isFalse);
  });

  test(
    'smoke completion after dispose keeps result without notifying',
    () async {
      final workspace = _TestWorkspace();
      final smokeCompleter = Completer<VaultApiSmokeReport>();
      final coordinator = ApiSmokeCoordinator(
        workspaceResolver: () async => workspace,
        runner:
            (
              workspace, {
              bool includeIntegrations = false,
              bool onlyImplemented = true,
            }) => smokeCompleter.future,
      );
      var notifications = 0;
      coordinator.addListener(() => notifications++);

      final run = coordinator.run();
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);
      coordinator.dispose();
      final report = VaultApiSmokeReport(
        platform: 'test',
        appVersion: 'test',
        workspaceId: workspace.workspaceId,
        results: const [],
        startedAt: DateTime(2026),
        finishedAt: DateTime(2026),
      );
      smokeCompleter.complete(report);

      expect(await run, same(report));
      expect(notifications, 1);
      expect(workspace.disposed, isTrue);
    },
  );
}
