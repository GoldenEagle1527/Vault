import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vault/agent/agent_inbox.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/sandbox_models.dart';

class _MemoryWorkspace implements SandboxWorkspace {
  final Map<String, Uint8List> files = {};

  @override
  String get workspaceId => 'inbox-test';

  @override
  Stream<Uint8List> get output => const Stream.empty();

  @override
  void write(String data) {}

  @override
  void writeBytes(Uint8List data) {}

  @override
  void resize(int cols, int rows) {}

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  Future<CommandResult> run(
    String cmd, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async => const CommandResult(exitCode: 0, stdout: '', stderr: '');

  @override
  Future<void> writeGuestFile(String guestAbsolutePath, List<int> bytes) async {
    files[assertGuestPathUnderHome(guestAbsolutePath)] = Uint8List.fromList(
      bytes,
    );
  }

  @override
  Future<Uint8List?> readGuestFile(String guestAbsolutePath) async {
    return files[assertGuestPathUnderHome(guestAbsolutePath)];
  }

  @override
  Future<List<GuestFsEntry>> listGuestDirectory(
    String guestAbsolutePath,
  ) async => const [];

  @override
  Future<void> dispose() async {}
}

Uint8List _png() {
  final image = img.Image(width: 16, height: 12);
  img.fill(image, color: img.ColorRgb8(1, 2, 3));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  test('paste image names are paste- + uuidv7', () {
    final name = newPasteImageFileName();
    expect(
      name,
      matches(
        RegExp(
          r'^paste-[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.png$',
          caseSensitive: false,
        ),
      ),
    );
    expect(newPasteImageFileName(), isNot(name));
  });

  test('inject writes into the current project inbox', () async {
    final ws = _MemoryWorkspace();
    final metas = await injectAttachmentsIntoInbox(
      ws,
      projectPath: 'proj-a',
      attachments: [
        AgentAttachment(bytes: utf8.encode('hello'), displayName: 'note.txt'),
      ],
    );
    expect(metas, hasLength(1));
    expect(metas.single.guestPath, '/root/projects/proj-a/inbox/note.txt');
    expect(metas.single.kind, GuestMediaKind.text);
    expect(ws.files['/root/projects/proj-a/inbox/note.txt'], isNotNull);
    expect(ws.files.containsKey('/root/inbox/note.txt'), isFalse);
  });

  test('projects do not share inbox files', () async {
    final ws = _MemoryWorkspace();
    await injectAttachmentsIntoInbox(
      ws,
      projectPath: 'alpha',
      attachments: [
        AgentAttachment(bytes: utf8.encode('a'), displayName: 'shared.txt'),
      ],
    );
    await injectAttachmentsIntoInbox(
      ws,
      projectPath: 'beta',
      attachments: [
        AgentAttachment(bytes: utf8.encode('b'), displayName: 'shared.txt'),
      ],
    );
    expect(
      utf8.decode(ws.files['/root/projects/alpha/inbox/shared.txt']!),
      'a',
    );
    expect(utf8.decode(ws.files['/root/projects/beta/inbox/shared.txt']!), 'b');
  });

  test('existing inbox name is auto-numbered', () async {
    final ws = _MemoryWorkspace();
    ws.files['/root/projects/p1/inbox/foo.png'] = _png();
    final metas = await injectAttachmentsIntoInbox(
      ws,
      projectPath: 'p1',
      attachments: [AgentAttachment(bytes: _png(), displayName: 'foo.png')],
    );
    expect(metas.single.displayName, 'foo-2.png');
    expect(metas.single.guestPath, '/root/projects/p1/inbox/foo-2.png');
  });
}
