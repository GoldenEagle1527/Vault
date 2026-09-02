import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/agent/workspace_mode.dart';
import 'package:vault/agent/workspace_store.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/screens/home/workspace_controller.dart';

class _DelayedProvider implements SandboxProvider {
  final probeCompleter = Completer<SandboxCapabilities>();
  final createCompleter = Completer<SandboxWorkspace>();
  final attachCompleter = Completer<SandboxWorkspace>();
  final destroyCompleter = Completer<void>();

  @override
  Future<SandboxCapabilities> probe() => probeCompleter.future;

  @override
  Future<SandboxWorkspace> create(
    String workspaceId, {
    WorkspaceInitProgressCallback? onProgress,
  }) => createCompleter.future;

  @override
  Future<SandboxWorkspace> attach(String workspaceId) => attachCompleter.future;

  @override
  Future<void> destroy(String workspaceId) => destroyCompleter.future;

  @override
  Future<List<WorkspaceInfo>> list() async => const [];

  @override
  Future<void> deleteGuestPath(
    String workspaceId,
    String guestAbsolutePath, {
    bool recursive = false,
  }) async {}

  @override
  Future<List<GuestFsEntry>> listGuestDirectory(
    String workspaceId,
    String guestAbsolutePath,
  ) async => const [];

  @override
  Future<Uint8List?> readGuestFile(
    String workspaceId,
    String guestAbsolutePath,
  ) async => null;

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
  Future<void> writeGuestFile(
    String workspaceId,
    String guestAbsolutePath,
    List<int> bytes,
  ) async {}
}

class _TestWorkspace implements SandboxWorkspace {
  _TestWorkspace(this.workspaceId);

  @override
  final String workspaceId;

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
  Future<List<GuestFsEntry>> listGuestDirectory(
    String guestAbsolutePath,
  ) async => const [];

  @override
  Future<void> dispose() async {}
}

class _Harness {
  _Harness()
    : directory = Directory.systemTemp.createTempSync('workspace_controller_') {
    final db = VaultMetaDb.at(p.join(directory.path, 'meta.db'));
    provider = _DelayedProvider();
    controller = WorkspaceController(
      provider: provider,
      metaDb: db,
      conversationStore: ConversationStore(metaDb: db),
      projectStore: ProjectStore.fromProvider(provider, metaDb: db),
      workspaceStore: WorkspaceStore(metaDb: db),
    );
  }

  final Directory directory;
  late final _DelayedProvider provider;
  late final WorkspaceController controller;

  void cleanUp() {
    try {
      directory.deleteSync(recursive: true);
    } catch (_) {}
  }
}

void main() {
  test('refresh completion after dispose does not notify', () async {
    final harness = _Harness();
    addTearDown(harness.cleanUp);
    var notifications = 0;
    harness.controller.addListener(() => notifications++);

    final refresh = harness.controller.refresh();
    expect(notifications, 1);
    harness.controller.dispose();
    harness.provider.probeCompleter.complete(
      const SandboxCapabilities(
        available: false,
        backend: SandboxBackend.unsupported,
        architecture: 'test',
      ),
    );

    await refresh;
    expect(notifications, 1);
  });

  test(
    'create completion after dispose returns workspace without notify',
    () async {
      final harness = _Harness();
      addTearDown(harness.cleanUp);
      var notifications = 0;
      harness.controller.addListener(() => notifications++);

      final creation = harness.controller.create(
        id: 'created',
        displayName: 'Created',
        mode: WorkspaceMode.chat,
      );
      harness.controller.dispose();
      final workspace = _TestWorkspace('created');
      harness.provider.createCompleter.complete(workspace);

      expect(await creation, same(workspace));
      expect(notifications, 1);
    },
  );

  test('attach failure after dispose still propagates', () async {
    final harness = _Harness();
    addTearDown(harness.cleanUp);
    final attachment = harness.controller.attach(
      WorkspaceInfo(
        workspaceId: 'missing',
        displayName: 'missing',
        createdAt: DateTime(2026),
      ),
    );
    harness.controller.dispose();
    harness.provider.attachCompleter.completeError(StateError('attach failed'));

    await expectLater(attachment, throwsA(isA<StateError>()));
  });

  test('destroy completion after dispose does not notify', () async {
    final harness = _Harness();
    addTearDown(harness.cleanUp);
    var notifications = 0;
    harness.controller.addListener(() => notifications++);

    final destruction = harness.controller.destroy('old');
    harness.controller.dispose();
    harness.provider.destroyCompleter.complete();

    await destruction;
    expect(notifications, 1);
  });
}
