import 'package:vault/sandbox/guest_media_kind.dart';

/// How the user added this file to the composer.
enum AgentAttachmentSource { picked, dropped, pasted }

/// Persisted / UI metadata for one user attachment (no file bytes).
class ChatAttachmentMeta {
  const ChatAttachmentMeta({
    required this.guestPath,
    required this.displayName,
    required this.kind,
  });

  final String guestPath;
  final String displayName;
  final GuestMediaKind kind;

  Map<String, dynamic> toJson() => {
    'guestPath': guestPath,
    'displayName': displayName,
    'kind': kind.name,
  };

  factory ChatAttachmentMeta.fromJson(Map<String, dynamic> json) {
    final kindName = (json['kind'] as String?) ?? 'binary';
    final kind = GuestMediaKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => guestMediaKindForPath(
        (json['guestPath'] as String?) ??
            (json['displayName'] as String?) ??
            '',
      ),
    );
    return ChatAttachmentMeta(
      guestPath: (json['guestPath'] as String?)?.trim() ?? '',
      displayName: (json['displayName'] as String?)?.trim() ?? '',
      kind: kind,
    );
  }

  static List<ChatAttachmentMeta> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    final out = <ChatAttachmentMeta>[];
    for (final item in raw) {
      if (item is Map) {
        out.add(ChatAttachmentMeta.fromJson(item.cast<String, dynamic>()));
      }
    }
    return out;
  }
}
