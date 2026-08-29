import 'dart:convert';

import 'package:vault/agent/chat_attachment.dart';
import 'package:vault/sandbox/guest_media_kind.dart';

const String kPresentFileToolName = 'present_file';

/// Parse a successful [present_file] tool result into chat attachment metadata.
ChatAttachmentMeta? presentFileAttachmentFromResult({
  Map<String, dynamic>? metadata,
  String? resultText,
}) {
  final fromMeta = _fromMap(metadata);
  if (fromMeta != null) return fromMeta;
  return _fromText(resultText);
}

Map<String, dynamic> presentFilePayload({
  required String guestPath,
  required String displayName,
  required GuestMediaKind kind,
  int? size,
}) {
  return {
    'present_file': true,
    'ok': true,
    'guestPath': guestPath,
    'displayName': displayName,
    'kind': kind.name,
    'size': ?size,
  };
}

ChatAttachmentMeta? _fromMap(Map<String, dynamic>? map) {
  if (map == null) return null;
  if (map['present_file'] != true || map['ok'] != true) return null;
  final guestPath = (map['guestPath'] as String?)?.trim() ?? '';
  if (guestPath.isEmpty) return null;
  final displayName = (map['displayName'] as String?)?.trim();
  final kindName = (map['kind'] as String?) ?? '';
  final kind = GuestMediaKind.values.firstWhere(
    (k) => k.name == kindName,
    orElse: () => guestMediaKindForPath(guestPath),
  );
  return ChatAttachmentMeta(
    guestPath: guestPath,
    displayName: (displayName == null || displayName.isEmpty)
        ? guestPath.split('/').last
        : displayName,
    kind: kind,
  );
}

ChatAttachmentMeta? _fromText(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  final trimmed = text.trim();
  final start = trimmed.lastIndexOf('{');
  final end = trimmed.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final decoded = jsonDecode(trimmed.substring(start, end + 1));
    if (decoded is Map) {
      return _fromMap(decoded.cast<String, dynamic>());
    }
  } catch (_) {}
  return null;
}
