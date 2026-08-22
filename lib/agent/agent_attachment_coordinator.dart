import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:super_clipboard/super_clipboard.dart';
import 'package:vault/agent/agent_inbox.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/util/host_file_picker.dart';

typedef AttachmentCollisionResolver =
    Future<String?> Function(String name, Set<String> taken);

class AgentAttachmentCoordinator {
  AgentAttachmentCoordinator({
    required this.provider,
    required this.workspaceId,
    required this.activeProjectPath,
    required this.resolveCollision,
    required this.onChanged,
  });

  final SandboxProvider provider;
  final String workspaceId;
  final String? Function() activeProjectPath;
  final AttachmentCollisionResolver resolveCollision;
  final void Function() onChanged;
  final List<AgentAttachment> pending = [];

  void clear() {
    if (pending.isEmpty) return;
    pending.clear();
    onChanged();
  }

  void removeAt(int index) {
    pending.removeAt(index);
    onChanged();
  }

  Future<List<AgentAttachment>> pickFiles() async {
    final result = await pickHostFilesForAgent(
      allowMultiple: true,
      withData: false,
    );
    if (result == null) return const [];
    return [
      for (final file in result.files)
        if (file.path != null && file.path!.isNotEmpty)
          AgentAttachment(
            hostPath: file.path,
            displayName: file.name,
            source: AgentAttachmentSource.picked,
          ),
    ];
  }

  List<AgentAttachment> fromDrop(DropDoneDetails details) {
    return [
      for (final item in details.files)
        if (item.path.isNotEmpty)
          AgentAttachment(
            hostPath: item.path,
            displayName: item.name.trim().isEmpty
                ? p.basename(item.path)
                : item.name.trim(),
            source: AgentAttachmentSource.dropped,
          ),
    ];
  }

  Future<bool> offer(List<AgentAttachment> incoming) async {
    final projectPath = activeProjectPath();
    if (incoming.isEmpty || projectPath == null) return false;
    final taken = {
      ...pending.map((attachment) {
        return sanitizeInboxFileName(attachment.displayName);
      }),
      ...await _inboxTakenNames(projectPath),
    };
    final accepted = <AgentAttachment>[];
    for (final attachment in incoming) {
      var name = sanitizeInboxFileName(attachment.displayName);
      if (taken.contains(name)) {
        final resolved = await resolveCollision(name, taken);
        if (resolved == null) continue;
        name = resolved;
      }
      taken.add(name);
      accepted.add(
        AgentAttachment(
          hostPath: attachment.hostPath,
          bytes: attachment.bytes,
          displayName: name,
          mimeType: attachment.mimeType,
          source: attachment.source,
        ),
      );
    }
    if (accepted.isEmpty) return false;
    pending.addAll(accepted);
    onChanged();
    return true;
  }

  Future<List<AgentAttachment>> readClipboardAttachments() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return const [];
    try {
      return await _attachmentsFromClipboard(await clipboard.read());
    } catch (_) {
      return const [];
    }
  }

  Future<void> pastePlainText(TextEditingController controller) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    final value = controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  Future<Set<String>> _inboxTakenNames(String projectPath) async {
    try {
      final entries = await provider.listGuestDirectory(
        workspaceId,
        guestProjectInboxDir(projectPath),
      );
      return {
        for (final entry in entries)
          if (!entry.isDirectory) entry.name,
      };
    } catch (_) {
      return {};
    }
  }

  Future<List<AgentAttachment>> _attachmentsFromClipboard(
    ClipboardReader reader,
  ) async {
    const imageFormats = <SimpleFileFormat>[
      Formats.png,
      Formats.jpeg,
      Formats.gif,
      Formats.webp,
      Formats.bmp,
    ];
    for (final format in imageFormats) {
      if (!reader.canProvide(format)) continue;
      final bytes = await _readClipboardFile(reader, format);
      if (bytes == null || bytes.isEmpty) continue;
      final extension = switch (format) {
        Formats.jpeg => 'jpg',
        Formats.gif => 'gif',
        Formats.webp => 'webp',
        Formats.bmp => 'bmp',
        _ => 'png',
      };
      return [
        AgentAttachment(
          bytes: bytes,
          displayName: newPasteImageFileName(extension: extension),
          mimeType: 'image/$extension',
          source: AgentAttachmentSource.pasted,
        ),
      ];
    }

    if (reader.canProvide(Formats.fileUri)) {
      final uri = await reader.readValue(Formats.fileUri);
      if (uri != null && uri.isScheme('file')) {
        final path = uri.toFilePath();
        if (path.isNotEmpty) {
          return [
            AgentAttachment(
              hostPath: path,
              displayName: p.basename(path),
              source: AgentAttachmentSource.pasted,
            ),
          ];
        }
      }
    }
    return const [];
  }

  Future<Uint8List?> _readClipboardFile(
    ClipboardReader reader,
    FileFormat format,
  ) {
    final completer = Completer<Uint8List?>();
    reader.getFile(
      format,
      (file) async {
        try {
          final bytes = await file.readAll();
          if (!completer.isCompleted) completer.complete(bytes);
        } catch (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => null,
    );
  }
}
