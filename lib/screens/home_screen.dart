import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/sandbox/workspace_guest_fs.dart';
import 'package:vault/screens/agent_screen.dart';
import 'package:vault/screens/settings_screen.dart';
import 'package:vault/widgets/appearance_sheet.dart';
import 'package:vault/widgets/glass.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.provider, this.conversationStore});

  final SandboxProvider provider;
  final ConversationStore? conversationStore;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _wideBreakpoint = 720.0;

  late final ConversationStore _conversationStore;
  SandboxCapabilities? _caps;
  List<WorkspaceInfo> _workspaces = const [];
  Map<String, WorkspaceConversationSummary> _summaries = const {};
  String? _error;
  bool _busy = false;
  int _navIndex = 0;
  bool _settingsVisited = false;

  @override
  void initState() {
    super.initState();
    _conversationStore = widget.conversationStore ??
        ConversationStore(fs: SandboxWorkspaceGuestFs(widget.provider));
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final caps = await widget.provider.probe();
      final workspaces = caps.available
          ? await widget.provider.list()
          : const <WorkspaceInfo>[];
      final summaries = <String, WorkspaceConversationSummary>{};
      for (final w in workspaces) {
        summaries[w.workspaceId] =
            await _conversationStore.peekWorkspaceSummary(w.workspaceId);
      }
      if (!mounted) return;
      setState(() {
        _caps = caps;
        _workspaces = workspaces;
        _summaries = summaries;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createWorkspace() async {
    if (_caps?.available != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final id = const Uuid().v4().replaceAll('-', '').substring(0, 12);
    try {
      final workspace = await widget.provider.create(id);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AgentScreen(
            title: '工作区 $id',
            workspace: workspace,
            conversationStore: _conversationStore,
          ),
        ),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openWorkspace(WorkspaceInfo info) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final workspace = await widget.provider.attach(info.workspaceId);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AgentScreen(
            title: info.displayName,
            workspace: workspace,
            conversationStore: _conversationStore,
          ),
        ),
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '打开工作区失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _destroyWorkspace(WorkspaceInfo info) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除工作区？'),
        content: Text(
          _caps?.backend == SandboxBackend.proot
              ? '将删除工作区 ${info.displayName} 的独立空间、全部会话历史，并结束相关进程。'
              : '将执行 wsl --unregister 卸载 ${info.displayName}，删除其磁盘文件与全部会话历史。'
                    '通常可回收约 1 GB 空间。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.provider.destroy(info.workspaceId);
      await _conversationStore.deleteWorkspace(info.workspaceId);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _formatBytes(int? bytes) {
    if (bytes == null) return '大小未知';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 5) return '夜深了';
    if (hour < 12) return '上午好';
    if (hour < 18) return '下午好';
    return '晚上好';
  }

  String _relativeTime(DateTime when) {
    final local = when.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final hm =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (day == today) return '今天 $hm';
    if (day == today.subtract(const Duration(days: 1))) return '昨天 $hm';
    return '${local.month} 月 ${local.day} 日';
  }

  IconData _workspaceIcon(String workspaceId) {
    const icons = [
      Icons.table_chart_outlined,
      Icons.photo_library_outlined,
      Icons.chat_bubble_outline,
      Icons.folder_outlined,
      Icons.analytics_outlined,
    ];
    return icons[workspaceId.hashCode.abs() % icons.length];
  }

  String _workspaceTitle(WorkspaceInfo info) {
    final summary = _summaries[info.workspaceId];
    final recent = summary?.recentTitle?.trim();
    if (recent != null &&
        recent.isNotEmpty &&
        recent != kNewConversationTitle) {
      return recent;
    }
    return info.displayName;
  }

  String _workspaceSubtitle(WorkspaceInfo info) {
    final summary = _summaries[info.workspaceId];
    final parts = <String>[
      _relativeTime(info.createdAt),
      _formatBytes(info.approxDiskBytes),
    ];
    final count = summary?.conversationCount ?? 0;
    if (count > 0) {
      parts.add('$count 个会话');
    }
    final recent = summary?.recentTitle;
    if (recent != null &&
        recent.isNotEmpty &&
        recent != kNewConversationTitle &&
        recent != info.displayName) {
      // Title already shows recent; keep meta only.
    } else if (recent == kNewConversationTitle) {
      parts.add('新会话');
    }
    return parts.join(' · ');
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => SettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final scheme = Theme.of(context).colorScheme;

    final destinations = const [
      NavigationDestination(
        icon: Icon(Icons.dashboard_outlined),
        selectedIcon: Icon(Icons.dashboard),
        label: '首页',
      ),
      NavigationDestination(
        icon: Icon(Icons.workspaces_outlined),
        selectedIcon: Icon(Icons.workspaces),
        label: '工作区',
      ),
      NavigationDestination(
        icon: Icon(Icons.settings_outlined),
        selectedIcon: Icon(Icons.settings),
        label: '设置',
      ),
    ];

    return AmbientBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Row(
          children: [
            if (wide) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 0, 10),
                child: GlassPanel(
                  borderRadius: 28,
                  tone: GlassTone.strong,
                  child: NavigationRail(
                    selectedIndex: _navIndex,
                    onDestinationSelected: (i) {
                      setState(() {
                        _navIndex = i;
                        if (i == 2) _settingsVisited = true;
                      });
                    },
                    labelType: NavigationRailLabelType.all,
                    leading: Padding(
                      padding: const EdgeInsets.only(bottom: 16, top: 8),
                      child: CircleAvatar(
                        radius: 28,
                        backgroundColor: scheme.primary,
                        foregroundColor: scheme.onPrimary,
                        child: const Icon(Icons.shield_outlined),
                      ),
                    ),
                    trailing: Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: IconButton(
                            tooltip: '外观',
                            onPressed: () => showAppearanceSheet(context),
                            icon: const Icon(Icons.palette_outlined),
                          ),
                        ),
                      ),
                    ),
                    destinations: [
                      for (final d in destinations)
                        NavigationRailDestination(
                          icon: d.icon,
                          selectedIcon: d.selectedIcon,
                          label: Text(d.label),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                children: [
                  if (_navIndex != 2)
                    SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: GlassPanel(
                          borderRadius: 22,
                          tone: GlassTone.regular,
                          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Vault',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                    Text(
                                      _navIndex == 1 ? '工作区' : '首页',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.headlineSmall,
                                    ),
                                  ],
                                ),
                              ),
                              if (_caps != null && wide)
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: _EnvChip(caps: _caps!),
                                ),
                              IconButton(
                                tooltip: '外观',
                                onPressed: () => showAppearanceSheet(context),
                                icon: const Icon(Icons.palette_outlined),
                              ),
                              IconButton(
                                tooltip: '刷新',
                                onPressed: _busy ? null : _refresh,
                                icon: const Icon(Icons.refresh),
                              ),
                              if (!wide)
                                IconButton(
                                  tooltip: '设置',
                                  onPressed: _openSettings,
                                  icon: const Icon(Icons.settings_outlined),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  Expanded(
                    child: IndexedStack(
                      index: _navIndex > 1 && !_settingsVisited ? 0 : _navIndex,
                      children: [
                        _HomePane(
                          greeting: _greeting(),
                          caps: _caps,
                          busy: _busy,
                          error: _error,
                          workspaces: _workspaces,
                          titleFor: _workspaceTitle,
                          subtitleFor: _workspaceSubtitle,
                          onDismissError: () => setState(() => _error = null),
                          onCreate: _busy || _caps?.available != true
                              ? null
                              : _createWorkspace,
                          onOpen: _busy ? null : _openWorkspace,
                          onDelete: _busy ? null : _destroyWorkspace,
                          onShowAll: () => setState(() => _navIndex = 1),
                          workspaceIcon: _workspaceIcon,
                        ),
                        _WorkspacesPane(
                          busy: _busy,
                          error: _error,
                          workspaces: _workspaces,
                          titleFor: _workspaceTitle,
                          subtitleFor: _workspaceSubtitle,
                          onDismissError: () => setState(() => _error = null),
                          onOpen: _busy ? null : _openWorkspace,
                          onDelete: _busy ? null : _destroyWorkspace,
                          workspaceIcon: _workspaceIcon,
                        ),
                        if (_settingsVisited)
                          SettingsScreen(embedded: true)
                        else
                          const SizedBox.shrink(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: wide
            ? null
            : Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: GlassPanel(
                  borderRadius: 28,
                  tone: GlassTone.strong,
                  child: NavigationBar(
                    selectedIndex: _navIndex,
                    onDestinationSelected: (i) {
                      setState(() {
                        _navIndex = i;
                        if (i == 2) _settingsVisited = true;
                      });
                    },
                    destinations: destinations,
                  ),
                ),
              ),
      ),
    );
  }
}

class _EnvChip extends StatelessWidget {
  const _EnvChip({required this.caps});

  final SandboxCapabilities caps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ready = caps.available;
    return Chip(
      avatar: Icon(
        ready ? Icons.check_circle : Icons.error_outline,
        size: 18,
        color: ready ? scheme.primary : scheme.error,
      ),
      label: Text(ready ? '安全环境已就绪' : '环境不可用'),
      side: BorderSide.none,
      backgroundColor: ready ? scheme.primaryContainer : scheme.errorContainer,
      labelStyle: TextStyle(
        color: ready ? scheme.onPrimaryContainer : scheme.onErrorContainer,
      ),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _HomePane extends StatelessWidget {
  const _HomePane({
    required this.greeting,
    required this.caps,
    required this.busy,
    required this.error,
    required this.workspaces,
    required this.titleFor,
    required this.subtitleFor,
    required this.onDismissError,
    required this.onCreate,
    required this.onOpen,
    required this.onDelete,
    required this.onShowAll,
    required this.workspaceIcon,
  });

  final String greeting;
  final SandboxCapabilities? caps;
  final bool busy;
  final String? error;
  final List<WorkspaceInfo> workspaces;
  final String Function(WorkspaceInfo) titleFor;
  final String Function(WorkspaceInfo) subtitleFor;
  final VoidCallback onDismissError;
  final VoidCallback? onCreate;
  final void Function(WorkspaceInfo)? onOpen;
  final void Function(WorkspaceInfo)? onDelete;
  final VoidCallback onShowAll;
  final IconData Function(String) workspaceIcon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final recent = workspaces.take(8).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        if (error != null) ...[
          MaterialBanner(
            content: Text(error!),
            actions: [
              TextButton(onPressed: onDismissError, child: const Text('关闭')),
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (caps != null && !caps!.available) ...[
          Card(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '环境不可用',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                  if (caps!.hint != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      caps!.hint!,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        FadeSlideIn(
          child: GlassPanel(
            borderRadius: 28,
            tone: GlassTone.tinted,
            tint: scheme.primaryContainer,
            padding: const EdgeInsets.all(24),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final stacked = constraints.maxWidth < 520;
                final text = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      greeting,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '今天想让 Vault 帮你做什么？',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '创建工作区后，可在同一 Linux 环境中开启多轮会话。',
                      style: TextStyle(color: scheme.onPrimaryContainer),
                    ),
                  ],
                );
                final button = FilledButton.icon(
                  onPressed: onCreate,
                  icon: const Icon(Icons.add),
                  label: const Text('新建工作区'),
                );
                if (stacked) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [text, const SizedBox(height: 20), button],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: text),
                    const SizedBox(width: 16),
                    button,
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '继续工作',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Text('最近工作区', style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            ),
            TextButton(onPressed: onShowAll, child: const Text('查看全部')),
          ],
        ),
        const SizedBox(height: 8),
        if (recent.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              busy ? '正在检查环境…' : '还没有工作区。点上方「新建工作区」开始。',
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
          )
        else
          ...recent.asMap().entries.map(
            (e) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: FadeSlideIn(
                index: e.key,
                child: _WorkspaceRow(
                  title: titleFor(e.value),
                  subtitle: subtitleFor(e.value),
                  icon: workspaceIcon(e.value.workspaceId),
                  primaryActionLabel: '继续',
                  onOpen: onOpen == null ? null : () => onOpen!(e.value),
                  onDelete: onDelete == null ? null : () => onDelete!(e.value),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _WorkspacesPane extends StatelessWidget {
  const _WorkspacesPane({
    required this.busy,
    required this.error,
    required this.workspaces,
    required this.titleFor,
    required this.subtitleFor,
    required this.onDismissError,
    required this.onOpen,
    required this.onDelete,
    required this.workspaceIcon,
  });

  final bool busy;
  final String? error;
  final List<WorkspaceInfo> workspaces;
  final String Function(WorkspaceInfo) titleFor;
  final String Function(WorkspaceInfo) subtitleFor;
  final VoidCallback onDismissError;
  final void Function(WorkspaceInfo)? onOpen;
  final void Function(WorkspaceInfo)? onDelete;
  final IconData Function(String) workspaceIcon;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        if (error != null) ...[
          MaterialBanner(
            content: Text(error!),
            actions: [
              TextButton(onPressed: onDismissError, child: const Text('关闭')),
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (workspaces.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Text(
              busy ? '加载中…' : '暂无工作区。',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          ...workspaces.asMap().entries.map(
            (e) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: FadeSlideIn(
                index: e.key,
                child: _WorkspaceRow(
                  title: titleFor(e.value),
                  subtitle: subtitleFor(e.value),
                  icon: workspaceIcon(e.value.workspaceId),
                  primaryActionLabel: '打开',
                  onOpen: onOpen == null ? null : () => onOpen!(e.value),
                  onDelete: onDelete == null ? null : () => onDelete!(e.value),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _WorkspaceRow extends StatelessWidget {
  const _WorkspaceRow({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.primaryActionLabel,
    required this.onOpen,
    required this.onDelete,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String primaryActionLabel;
  final VoidCallback? onOpen;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 600;

    return PressableScale(
      onTap: onOpen,
      enabled: onOpen != null,
      child: GlassPanel(
        borderRadius: 20,
        tone: GlassTone.regular,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: scheme.primaryContainer.withValues(alpha: 0.85),
              foregroundColor: scheme.onPrimaryContainer,
              child: Icon(icon),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (wide) ...[
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: onOpen,
                child: Text(primaryActionLabel),
              ),
            ],
            IconButton(
              tooltip: '删除',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}
