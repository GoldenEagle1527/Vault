import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:vault/sandbox/sandbox_models.dart';

/// A host file the user selected to inject into the session inbox.
class AgentAttachment {
  const AgentAttachment({
    required this.hostPath,
    required this.displayName,
  });

  final String hostPath;
  final String displayName;
}

/// Copy user attachments into [kGuestInboxDir] inside [session].
///
/// Returns guest absolute paths that were written.
Future<List<String>> injectAttachmentsIntoInbox(
  SandboxSession session,
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
    await session.writeGuestFile(guestPath, bytes);
    guestPaths.add(guestPath);
  }

  return guestPaths;
}
