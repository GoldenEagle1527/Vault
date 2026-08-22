import 'package:vault_agent_core/vault_agent_core.dart';

/// Empty / untitled conversation label shown in the UI.
const kNewConversationTitle = '新会话';

/// Metadata for one Agent conversation inside a project.
class ConversationInfo {
  const ConversationInfo({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.messageCount,
    this.parentId,
    this.forkedFromMessageIndex,
    this.headTreeSha,
  });

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int messageCount;
  final String? parentId;
  final int? forkedFromMessageIndex;
  final String? headTreeSha;

  bool get isBranch => parentId != null && parentId!.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'messageCount': messageCount,
    if (parentId != null) 'parentId': parentId,
    if (forkedFromMessageIndex != null)
      'forkedFromMessageIndex': forkedFromMessageIndex,
    if (headTreeSha != null) 'headTreeSha': headTreeSha,
  };

  factory ConversationInfo.fromJson(Map<String, dynamic> json) {
    return ConversationInfo(
      id: json['id'] as String,
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? (json['title'] as String).trim()
          : kNewConversationTitle,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      messageCount: (json['messageCount'] as num?)?.toInt() ?? 0,
      parentId: json['parentId'] as String?,
      forkedFromMessageIndex: (json['forkedFromMessageIndex'] as num?)?.toInt(),
      headTreeSha: json['headTreeSha'] as String?,
    );
  }

  ConversationInfo copyWith({
    String? title,
    DateTime? updatedAt,
    int? messageCount,
    String? parentId,
    int? forkedFromMessageIndex,
    String? headTreeSha,
  }) {
    return ConversationInfo(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      messageCount: messageCount ?? this.messageCount,
      parentId: parentId ?? this.parentId,
      forkedFromMessageIndex:
          forkedFromMessageIndex ?? this.forkedFromMessageIndex,
      headTreeSha: headTreeSha ?? this.headTreeSha,
    );
  }
}

/// Index of conversations for one project.
class WorkspaceConversationIndex {
  const WorkspaceConversationIndex({
    required this.activeConversationId,
    required this.conversations,
  });

  final String? activeConversationId;
  final List<ConversationInfo> conversations;

  Map<String, dynamic> toJson() => {
    'activeConversationId': activeConversationId,
    'conversations': conversations.map((c) => c.toJson()).toList(),
  };

  factory WorkspaceConversationIndex.fromJson(Map<String, dynamic> json) {
    final list = (json['conversations'] as List? ?? const [])
        .map((e) => ConversationInfo.fromJson(e as Map<String, dynamic>))
        .toList();
    return WorkspaceConversationIndex(
      activeConversationId: json['activeConversationId'] as String?,
      conversations: list,
    );
  }

  static const empty = WorkspaceConversationIndex(
    activeConversationId: null,
    conversations: [],
  );
}

/// Lightweight summary for the home workspace list.
class WorkspaceConversationSummary {
  const WorkspaceConversationSummary({
    required this.conversationCount,
    this.recentTitle,
    this.recentUpdatedAt,
    this.projectCount = 0,
  });

  final int conversationCount;
  final String? recentTitle;
  final DateTime? recentUpdatedAt;
  final int projectCount;
}

String conversationTitleFromMessages(List<LLMMessage> messages) {
  for (final m in messages) {
    if (m is! UserMessage) continue;
    final text = m.contents
        .whereType<TextPart>()
        .map((p) => p.text)
        .join('\n')
        .trim();
    if (text.isEmpty) continue;
    final forTitle = text
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('[Vault'))
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (forTitle.isEmpty) continue;
    if (forTitle.length <= 24) return forTitle;
    return '${forTitle.substring(0, 24)}…';
  }
  return kNewConversationTitle;
}

List<ConversationInfo> conversationBranchesAt({
  required List<ConversationInfo> conversations,
  required String currentId,
  required int messageIndex,
}) {
  ConversationInfo? current;
  for (final c in conversations) {
    if (c.id == currentId) current = c;
  }
  if (current == null) return const [];
  final out = <ConversationInfo>[];
  void add(ConversationInfo c) {
    if (c.id == currentId || out.any((e) => e.id == c.id)) return;
    out.add(c);
  }

  for (final c in conversations) {
    if (c.parentId == currentId && c.forkedFromMessageIndex == messageIndex) {
      add(c);
    }
  }
  if (current.parentId != null &&
      current.forkedFromMessageIndex == messageIndex) {
    for (final c in conversations) {
      if (c.id == current.parentId) add(c);
      if (c.parentId == current.parentId &&
          c.forkedFromMessageIndex == messageIndex) {
        add(c);
      }
    }
  }
  return out;
}

List<({ConversationInfo info, int depth})> orderConversationTree(
  List<ConversationInfo> conversations,
) {
  final byParent = <String?, List<ConversationInfo>>{};
  for (final c in conversations) {
    byParent.putIfAbsent(c.parentId, () => []).add(c);
  }
  final ids = {for (final c in conversations) c.id};
  final out = <({ConversationInfo info, int depth})>[];
  void walk(ConversationInfo node, int depth) {
    out.add((info: node, depth: depth));
    final kids = [...?byParent[node.id]]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    for (final child in kids) {
      walk(child, depth + 1);
    }
  }

  final roots =
      conversations
          .where((c) => c.parentId == null || !ids.contains(c.parentId))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  for (final root in roots) {
    walk(root, 0);
  }
  return out;
}
