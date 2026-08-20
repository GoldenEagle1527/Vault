import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';
import 'package:vault/agent/chat_attachment.dart';
import 'package:vault/agent/image_prepare.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/sandbox_models.dart';

export 'package:vault/agent/chat_attachment.dart';

/// A host file or in-memory blob to inject into the project's inbox.
class AgentAttachment {
  const AgentAttachment({
    this.hostPath,
    this.bytes,
    required this.displayName,
    this.mimeType,
    this.source = AgentAttachmentSource.picked,
  });

  final String? hostPath;
  final Uint8List? bytes;
  final String displayName;
  final String? mimeType;
  final AgentAttachmentSource source;

  bool get isPastedImage => source == AgentAttachmentSource.pasted;
}

String newPasteImageFileName({String extension = 'png'}) {
  final ext = extension.startsWith('.') ? extension.substring(1) : extension;
  return 'paste-${const Uuid().v7()}.$ext';
}

/// Copy user attachments into the current project's `inbox/`.
Future<List<ChatAttachmentMeta>> injectAttachmentsIntoInbox(
  SandboxWorkspace workspace, {
  required String projectPath,
  required List<AgentAttachment> attachments,
}) async {
  if (attachments.isEmpty) return const [];

  final projectDir = guestProjectDir(projectPath);
  final inboxDir = guestProjectInboxDir(projectPath);
  await workspace.run(
    'mkdir -p ${shellSingleQuote(inboxDir)} && '
    'cd ${shellSingleQuote(projectDir)} && '
    'if [ ! -f .gitignore ] || ! grep -qxF "inbox/" .gitignore; then '
    'printf "inbox/\\n" >> .gitignore; fi',
  );

  final taken = <String>{};
  final metas = <ChatAttachmentMeta>[];

  for (final a in attachments) {
    var rawBytes = a.bytes;
    if (rawBytes == null) {
      final host = a.hostPath;
      if (host == null || host.isEmpty) {
        throw StateError('附件 ${a.displayName} 没有可读数据');
      }
      rawBytes = await File(host).readAsBytes();
    }

    var name = sanitizeInboxFileName(a.displayName);
    var writeBytes = rawBytes;
    final kindHint = guestMediaKindForPath(name);
    if (kindHint == GuestMediaKind.image ||
        (a.mimeType?.startsWith('image/') ?? false)) {
      final prepared = prepareImageForModel(rawBytes, hintExtension: name);
      writeBytes = prepared.bytes;
      if (prepared.compressed || a.isPastedImage) {
        final stem = name.contains('.')
            ? name.substring(0, name.lastIndexOf('.'))
            : name;
        name = sanitizeInboxFileName('$stem.${prepared.extension}');
      }
    }

    final diskTaken = Set<String>.from(taken);
    name = allocateInboxFileName(name, diskTaken);
    var guestPath = projectInboxGuestPath(projectPath, name);
    while (await workspace.readGuestFile(guestPath) != null) {
      diskTaken.add(name);
      name = allocateInboxFileName(name, diskTaken);
      guestPath = projectInboxGuestPath(projectPath, name);
    }
    taken.add(name);

    await workspace.writeGuestFile(guestPath, writeBytes);
    metas.add(
      ChatAttachmentMeta(
        guestPath: guestPath,
        displayName: name,
        kind: guestMediaKindForPath(name),
      ),
    );
  }

  return metas;
}
