import 'package:flutter/material.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/workspace_mode.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/widgets/workspace_mode_dialog.dart';

class HomeWorkspaceItemViewModel {
  const HomeWorkspaceItemViewModel({
    required this.info,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final WorkspaceInfo info;
  final String title;
  final String subtitle;
  final IconData icon;
}

class HomeViewModel {
  const HomeViewModel({
    required this.greeting,
    required this.busy,
    required this.canCreate,
    required this.workspaces,
    this.capabilities,
    this.error,
  });

  final String greeting;
  final bool busy;
  final bool canCreate;
  final SandboxCapabilities? capabilities;
  final String? error;
  final List<HomeWorkspaceItemViewModel> workspaces;
}

HomeViewModel buildHomeViewModel({
  required SandboxCapabilities? capabilities,
  required bool busy,
  required String? error,
  required List<WorkspaceInfo> workspaces,
  required Map<String, WorkspaceConversationSummary> summaries,
  required Map<String, WorkspaceMode> modes,
  required Map<String, String> names,
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  return HomeViewModel(
    greeting: _greeting(clock.hour),
    busy: busy,
    canCreate: !busy && capabilities?.available == true,
    capabilities: capabilities,
    error: error,
    workspaces: [
      for (final info in workspaces)
        HomeWorkspaceItemViewModel(
          info: info,
          title: _title(info, summaries[info.workspaceId], names),
          subtitle: _subtitle(
            info,
            summaries[info.workspaceId],
            modes[info.workspaceId] ?? WorkspaceMode.chat,
            names,
            clock,
          ),
          icon: _workspaceIcon(info.workspaceId),
        ),
    ],
  );
}

String resolvedWorkspaceName(WorkspaceInfo info, Map<String, String> names) {
  final named = names[info.workspaceId]?.trim();
  return named != null && named.isNotEmpty ? named : info.displayName;
}

String _title(
  WorkspaceInfo info,
  WorkspaceConversationSummary? summary,
  Map<String, String> names,
) {
  final named = names[info.workspaceId]?.trim();
  if (named != null && named.isNotEmpty) return named;
  final recent = summary?.recentTitle?.trim();
  if (recent != null && recent.isNotEmpty && recent != kNewConversationTitle) {
    return recent;
  }
  return info.displayName;
}

String _subtitle(
  WorkspaceInfo info,
  WorkspaceConversationSummary? summary,
  WorkspaceMode mode,
  Map<String, String> names,
  DateTime now,
) {
  final parts = <String>[
    workspaceModeLabel(mode),
    _relativeTime(info.createdAt, now),
    _formatBytes(info.approxDiskBytes),
  ];
  final projectCount = summary?.projectCount ?? 0;
  if (projectCount > 0) parts.add('$projectCount 个项目');
  final count = summary?.conversationCount ?? 0;
  if (count > 0) parts.add('$count 个会话');
  if (summary?.recentTitle == kNewConversationTitle) parts.add('新会话');
  return parts.join(' · ');
}

String _greeting(int hour) {
  if (hour < 5) return '夜深了';
  if (hour < 12) return '上午好';
  if (hour < 18) return '下午好';
  return '晚上好';
}

String _relativeTime(DateTime when, DateTime now) {
  final local = when.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final hm =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (day == today) return '今天 $hm';
  if (day == today.subtract(const Duration(days: 1))) return '昨天 $hm';
  return '${local.month} 月 ${local.day} 日';
}

String _formatBytes(int? bytes) {
  if (bytes == null) return '大小未知';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

IconData _workspaceIcon(String id) {
  const icons = [
    Icons.table_chart_outlined,
    Icons.photo_library_outlined,
    Icons.chat_bubble_outline,
    Icons.folder_outlined,
    Icons.analytics_outlined,
  ];
  return icons[id.hashCode.abs() % icons.length];
}
