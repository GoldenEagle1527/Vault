import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/sandbox/guest_fs_ops.dart';
import 'package:vault/sandbox/sandbox_provider.dart';

class _LocalSandboxProvider implements SandboxProvider {
  _LocalSandboxProvider(this.root);

  final Directory root;
  int writeGuestFileCalls = 0;

  String _host(String workspaceId, String guestAbsolutePath) {
    final guest = assertGuestPathUnderHome(guestAbsolutePath);
    return p.join(root.path, workspaceId, guest.substring(1));
  }

  @override
  Future<SandboxCapabilities> probe() async => const SandboxCapabilities(
    available: true,
    backend: SandboxBackend.unsupported,
    architecture: 'test',
  );

  @override
  Future<SandboxWorkspace> create(
    String workspaceId, {
    WorkspaceInitProgressCallback? onProgress,
  }) => throw UnimplementedError();

  @override
  Future<SandboxWorkspace> attach(String workspaceId) =>
      throw UnimplementedError();

  @override
  Future<void> destroy(String workspaceId) async {}

  @override
  Future<List<WorkspaceInfo>> list() async => const [];

  @override
  Future<Uint8List?> readGuestFile(
    String workspaceId,
    String guestAbsolutePath,
  ) async {
    final file = File(_host(workspaceId, guestAbsolutePath));
    if (!await file.exists()) return null;
    return Uint8List.fromList(await file.readAsBytes());
  }

  @override
  Future<void> writeGuestFile(
    String workspaceId,
    String guestAbsolutePath,
    List<int> bytes,
  ) async {
    writeGuestFileCalls++;
    final file = File(_host(workspaceId, guestAbsolutePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> deleteGuestPath(
    String workspaceId,
    String guestAbsolutePath, {
    bool recursive = false,
  }) async {
    final path = _host(workspaceId, guestAbsolutePath);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: recursive);
    } else if (type != FileSystemEntityType.notFound) {
      await File(path).delete();
    }
  }

  @override
  Future<List<GuestFsEntry>> listGuestDirectory(
    String workspaceId,
    String guestAbsolutePath,
  ) async => const [];

  @override
  Future<String> resolveGuestHostPath(
    String workspaceId,
    String guestAbsolutePath,
  ) async => _host(workspaceId, guestAbsolutePath);

  @override
  Future<CommandResult> runGuestCommand(String workspaceId, String cmd) async =>
      const CommandResult(exitCode: 1, stdout: '', stderr: 'unused');

  @override
  Future<void> stopRunningGuests() async {}
}

void main() {
  late Directory tmp;
  late _LocalSandboxProvider provider;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vault_fs_ops_');
    provider = _LocalSandboxProvider(tmp);
    await Directory(p.join(tmp.path, 'ws', 'root')).create(recursive: true);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('create empty file and folder', () async {
    final file = await createGuestEmptyFile(
      provider: provider,
      workspaceId: 'ws',
      guestDir: '/root',
      fileName: 'a.txt',
    );
    expect(file, '/root/a.txt');
    expect(
      await File(p.join(tmp.path, 'ws', 'root', 'a.txt')).exists(),
      isTrue,
    );

    final dir = await createGuestEmptyDirectory(
      provider: provider,
      workspaceId: 'ws',
      guestDir: '/root',
      dirName: 'docs',
    );
    expect(dir, '/root/docs');
    expect(
      await Directory(p.join(tmp.path, 'ws', 'root', 'docs')).exists(),
      isTrue,
    );
  });

  test('import renames on conflict', () async {
    final host = File(p.join(tmp.path, 'host.txt'));
    await host.writeAsString('one');
    await importHostFileToGuest(
      provider: provider,
      workspaceId: 'ws',
      guestDir: '/root',
      hostPath: host.path,
      displayName: 'note.txt',
    );
    await host.writeAsString('two');
    final second = await importHostFileToGuest(
      provider: provider,
      workspaceId: 'ws',
      guestDir: '/root',
      hostPath: host.path,
      displayName: 'note.txt',
    );
    expect(second, '/root/note-2.txt');
  });

  test('import streams large file without writeGuestFile', () async {
    final payload = Uint8List(256 * 1024);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = i & 0xff;
    }
    final host = File(p.join(tmp.path, 'big.bin'));
    await host.writeAsBytes(payload, flush: true);
    provider.writeGuestFileCalls = 0;

    final guest = await importHostFileToGuest(
      provider: provider,
      workspaceId: 'ws',
      guestDir: '/root',
      hostPath: host.path,
      displayName: 'big.bin',
    );

    expect(guest, '/root/big.bin');
    expect(provider.writeGuestFileCalls, 0);
    expect(
      await File(p.join(tmp.path, 'ws', 'root', 'big.bin')).readAsBytes(),
      payload,
    );
  });

  test('ensureGuestChildDirectory unique', () async {
    final first = await ensureGuestChildDirectory(
      provider: provider,
      workspaceId: 'ws',
      guestDir: '/root',
      dirName: 'pack',
      unique: true,
    );
    final second = await ensureGuestChildDirectory(
      provider: provider,
      workspaceId: 'ws',
      guestDir: '/root',
      dirName: 'pack',
      unique: true,
    );
    expect(first, '/root/pack');
    expect(second, '/root/pack-2');
  });

  test('rename and copy guest paths', () async {
    await createGuestEmptyFile(
      provider: provider,
      workspaceId: 'ws',
      guestDir: '/root',
      fileName: 'old.txt',
    );
    await renameGuestPath(
      provider: provider,
      workspaceId: 'ws',
      fromPath: '/root/old.txt',
      toPath: '/root/new.txt',
    );
    expect(
      await File(p.join(tmp.path, 'ws', 'root', 'new.txt')).exists(),
      isTrue,
    );
    expect(
      await File(p.join(tmp.path, 'ws', 'root', 'old.txt')).exists(),
      isFalse,
    );

    await copyGuestPath(
      provider: provider,
      workspaceId: 'ws',
      fromPath: '/root/new.txt',
      toPath: '/root/copy.txt',
    );
    expect(
      await File(p.join(tmp.path, 'ws', 'root', 'copy.txt')).exists(),
      isTrue,
    );

    final unique = await allocateUniqueGuestPath(
      provider: provider,
      workspaceId: 'ws',
      guestDir: '/root',
      fileName: 'new.txt',
    );
    expect(unique, '/root/new-2.txt');
  });
}
