import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/sandbox/guest_export_archive.dart';
import 'package:vault/sandbox/sandbox_provider.dart';

class _LocalSandboxProvider implements SandboxProvider {
  _LocalSandboxProvider(this.root);

  final Directory root;

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
    return file.readAsBytes();
  }

  @override
  Future<void> writeGuestFile(
    String workspaceId,
    String guestAbsolutePath,
    List<int> bytes,
  ) async {
    final file = File(_host(workspaceId, guestAbsolutePath));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

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
  test('allocateArchiveEntryName uniquifies and sanitizes', () {
    expect(allocateArchiveEntryName('note.txt', {}), 'note.txt');
    expect(allocateArchiveEntryName('note.txt', {'note.txt'}), 'note-2.txt');
    expect(
      allocateArchiveEntryName('note.txt', {'note.txt', 'note-2.txt'}),
      'note-3.txt',
    );
    expect(allocateArchiveEntryName('foo:bar.txt', {}), 'foo_bar.txt');
    expect(allocateArchiveEntryName('../escape.txt', {}), 'escape.txt');
  });

  test('zipFileNameForSelection uses first stem', () {
    expect(zipFileNameForSelection(const []), 'export.zip');
    expect(zipFileNameForSelection(['/root/notes.csv']), 'notes.zip');
    expect(
      zipFileNameForSelection(['/root/notes.csv', '/root/b']),
      'notes-and-2.zip',
    );
  });

  test('zipGuestPathsToHost writes unique entries', () async {
    final tmp = await Directory.systemTemp.createTemp('vault_zip_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    await Directory(
      p.join(tmp.path, 'ws', 'root', 'a'),
    ).create(recursive: true);
    await Directory(
      p.join(tmp.path, 'ws', 'root', 'b'),
    ).create(recursive: true);
    await File(
      p.join(tmp.path, 'ws', 'root', 'a', 'note.txt'),
    ).writeAsString('one', flush: true);
    await File(
      p.join(tmp.path, 'ws', 'root', 'b', 'note.txt'),
    ).writeAsString('two', flush: true);

    final dest = p.join(tmp.path, 'out.zip');
    await zipGuestPathsToHost(
      provider: _LocalSandboxProvider(tmp),
      workspaceId: 'ws',
      guestPaths: ['/root/a/note.txt', '/root/b/note.txt'],
      destZipPath: dest,
    );

    final archive = ZipDecoder().decodeBytes(await File(dest).readAsBytes());
    final names = archive.map((e) => e.name.replaceAll('\\', '/')).toSet();
    expect(names, containsAll({'note.txt', 'note-2.txt'}));
    final byName = {for (final e in archive) e.name.replaceAll('\\', '/'): e};
    expect(
      String.fromCharCodes(byName['note.txt']!.content as List<int>),
      'one',
    );
    expect(
      String.fromCharCodes(byName['note-2.txt']!.content as List<int>),
      'two',
    );
  });
}
