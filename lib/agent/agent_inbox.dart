import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:vault/sandbox/sandbox_models.dart';

/// A host file the user selected to inject into the workspace inbox.
class AgentAttachment {
  const AgentAttachment({
    required this.hostPath,
    required this.displayName,
  });

  final String hostPath;
  final String displayName;
}

/// Copy user attachments into [kGuestInboxDir] inside [workspace].
///
/// Returns guest absolute paths that were written.
Future<List<String>> injectAttachmentsIntoInbox(
  SandboxWorkspace workspace,
  List<AgentAttachment> attachments,
) async {
  if (attachments.isEmpty) return const [];

  final used = <String>{};
  final guestPaths = <String>[];

  for (final a in attachments) {
    var name = sanitizeInboxFileName(a.displayName);
    // Avoid collisions within one turn.
    if (used.contains(name)) {
      final stem = p.basenameWithoutExtension(name);
      final ext = p.extension(name);
      var i = 2;
      while (used.contains('$stem-$i$ext')) {
        i++;
      }
      name = '$stem-$i$ext';
    }
    used.add(name);

    final guestPath = inboxGuestPath(name);
    final bytes = await File(a.hostPath).readAsBytes();
    await workspace.writeGuestFile(guestPath, bytes);
    guestPaths.add(guestPath);
  }

  return guestPaths;
}
