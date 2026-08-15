import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/agent/workspace_mode.dart';
import 'package:vault/agent/workspace_store.dart';
import 'package:vault/sandbox/network_reachability.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/permissions/active_workspace_holder.dart';
import 'package:vault/permissions/offload_permission_dialog.dart';
import 'package:vault/screens/agent_screen.dart';
import 'package:vault/screens/settings_screen.dart';
import 'package:vault/theme/glass_tokens.dart';
import 'package:vault/widgets/glass.dart';
import 'package:vault/widgets/new_workspace_dialog.dart';
import 'package:vault/widgets/workspace_init_dialog.dart';
import 'package:vault/widgets/workspace_mode_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.provider,
    this.metaDb,
    this.conversationStore,
    this.projectStore,
    this.workspaceStore,
  });

  final SandboxProvider provider;
  final VaultMetaDb? metaDb;
  final ConversationStore? conversationStore;
  final ProjectStore? projectStore;
  final WorkspaceStore? workspaceStore;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _wideBreakpoint = 720.0;
  static const _chromeRailWidth = 80.0;
  static const _chromeItemHeight = 64.0;
  static const _chromeInnerRadius = 24.0;

  VaultMetaDb? _metaDb;
  ConversationStore? _conversationStore;
  ProjectStore? _projectStore;
  WorkspaceStore? _workspaceStore;
  bool _storesReady = false;
  SandboxCapabilities? _caps;
  List<WorkspaceInfo> _workspaces = const [];
  Map<String, WorkspaceConversationSummary> _summaries = const {};
  Map<String, WorkspaceMode> _modes = const {};
  Map<String, String> _names = const {};
  String? _error;
  bool _busy = false;
  int _navIndex = 0;
  bool _settingsVisited = false;

  @override
  void initState() {
    super.initState();
    // Settings smoke: temporarily attach first workspace when none is open.
    ActiveWorkspaceHolder.resolver = _resolveWorkspaceForSmoke;
    final injected = widget.metaDb;
    if (injected != null) {
      _metaDb = injected;
      _conversationStore =
          widget.conversationStore ?? ConversationStore(metaDb: injected);
      _projectStore =
          widget.projectStore ??
          ProjectStore.fromProvider(widget.provider, metaDb: injected);
      _workspaceStore =
          widget.workspaceStore ?? WorkspaceStore(metaDb: injected);
      _storesReady = true;
      unawaited(_refresh());
    } else {
      unawaited(_initStores());
    }
  }

  Future<void> _initStores() async {
    try {
      final metaDb = await VaultMetaDb.openDefault();
      final conversationStore =
          widget.conversationStore ?? ConversationStore(metaDb: metaDb);
      final projectStore =
          widget.projectStore ??
          ProjectStore.fromProvider(widget.provider, metaDb: metaDb);
      final workspaceStore =
          widget.workspaceStore ?? WorkspaceStore(metaDb: metaDb);
      if (!mounted) return;
      setState(() {
        _metaDb = metaDb;
        _conversationStore = conversationStore;
        _projectStore = projectStore;
        _workspaceStore = workspaceStore;
        _storesReady = true;
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '初始化元数据库失败：$e';
        _storesReady = true;
      });
    }
  }

  @override
  void dispose() {
    if (identical(ActiveWorkspaceHolder.resolver, _resolveWorkspaceForSmoke)) {
      ActiveWorkspaceHolder.resolver = null;
    }
    super.dispose();
  }

  /// Used by Settings 「运行全部 API 自检」 when no AgentScreen holds [current].
  Future<SandboxWorkspace?> _resolveWorkspaceForSmoke() async {
    if (_workspaces.isEmpty) return null;
    if (_caps?.available != true) return null;
    return widget.provider.attach(_workspaces.first.workspaceId);
  }

  Future<void> _refresh() async {
    if (!_storesReady || _projectStore == null || _conversationStore == null) {
      return;
    }
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
      final modes = <String, WorkspaceMode>{};
      final projectsStore = _projectStore!;
      final conversationsStore = _conversationStore!;
      final workspaceStore = _workspaceStore;
      final names = workspaceStore == null
          ? <String, String>{}
          : await workspaceStore.listNames();
      for (final w in workspaces) {
        try {
          final projects = await projectsStore.list(w.workspaceId);
          summaries[w.workspaceId] = await conversationsStore
              .peekProjectsSummary(
                w.workspaceId,
                projects.map((p) => p.path).toList(),
              );
        } catch (_) {
          summaries[w.workspaceId] = const WorkspaceConversationSummary(
            conversationCount: 0,
            projectCount: 0,
          );
        }
        try {
          modes[w.workspaceId] = workspaceStore == null
              ? WorkspaceMode.chat
              : await workspaceStore.getMode(w.workspaceId);
        } catch (_) {
          modes[w.workspaceId] = WorkspaceMode.chat;
        }
      }
      if (!mounted) return;
      setState(() {
        _caps = caps;
        _workspaces = workspaces;
        _summaries = summaries;
        _modes = modes;
        _names = names;
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
    final conversationStore = _conversationStore;
    final projectStore = _projectStore;
    final workspaceStore = _workspaceStore;
    if (conversationStore == null ||
        projectStore == null ||
        workspaceStore == null) {
      return;
    }
    final existingNames = _names.values.where((n) => n.trim().isNotEmpty);
    final typedName = await showNewWorkspaceDialog(
      context,
      existingNames: existingNames,
    );
    if (typedName == null || !mounted) return;
    final selectedMode = await showWorkspaceModeDialog(context);
    if (selectedMode == null || !mounted) return;
    final displayName = WorkspaceStore.allocateDisplayName(
      existingNames,
      base: typedName,
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    final id = const Uuid().v4().replaceAll('-', '').substring(0, 12);
    try {
      final online = await hasOutboundNetwork();
      if (!mounted) return;
      if (!online) {
        setState(() {
          _error = '当前无法联网，已取消初始化工作区。请连接网络后重试。';
        });
        return;
      }
      final workspace = await runWithWorkspaceInitDialog(
        context: context,
        action: (report) => widget.provider.create(id, onProgress: report),
      );
      if (!mounted) return;
      await workspaceStore.setName(id, displayName);
      await workspaceStore.setMode(id, selectedMode);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AgentScreen(
            title: displayName,
            provider: widget.provider,
            workspace: workspace,
            conversationStore: conversationStore,
            projectStore: projectStore,
            mode: selectedMode,
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
    final conversationStore = _conversationStore;
    final projectStore = _projectStore;
    final workspaceStore = _workspaceStore;
    if (conversationStore == null || projectStore == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final mode = workspaceStore == null
          ? WorkspaceMode.chat
          : await workspaceStore.getMode(info.workspaceId);
      final workspace = await widget.provider.attach(info.workspaceId);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AgentScreen(
            title: _resolvedName(info),
            provider: widget.provider,
            workspace: workspace,
            conversationStore: conversationStore,
            projectStore: projectStore,
            mode: mode,
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
              ? '将删除工作区 ${_resolvedName(info)} 的独立空间、全部会话历史，并结束相关进程。'
              : '将执行 wsl --unregister 卸载 ${_resolvedName(info)}，删除其磁盘文件与全部会话历史。'
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
      await _metaDb?.deleteWorkspace(info.workspaceId);
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

  String _resolvedName(WorkspaceInfo info) {
    final named = _names[info.workspaceId]?.trim();
    if (named != null && named.isNotEmpty) return named;
    return info.displayName;
  }

  String _workspaceTitle(WorkspaceInfo info) {
    final named = _names[info.workspaceId]?.trim();
    if (named != null && named.isNotEmpty) return named;
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
    final mode = _modes[info.workspaceId] ?? WorkspaceMode.chat;
    final parts = <String>[
      workspaceModeLabel(mode),
      _relativeTime(info.createdAt),
      _formatBytes(info.approxDiskBytes),
    ];
    final projectCount = summary?.projectCount ?? 0;
    if (projectCount > 0) {
      parts.add('$projectCount 个项目');
    }
    final count = summary?.conversationCount ?? 0;
    if (count > 0) {
      parts.add('$count 个会话');
    }
    final recent = summary?.recentTitle;
    if (recent != null &&
        recent.isNotEmpty &&
        recent != kNewConversationTitle &&
        recent != _resolvedName(info)) {
      // Title already shows recent; keep meta only.
    } else if (recent == kNewConversationTitle) {
      parts.add('新会话');
    }
    return parts.join(' · ');
  }

  void _selectNav(int i) {
    setState(() {
      _navIndex = i;
      if (i == 1) _settingsVisited = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    final scheme = Theme.of(context).colorScheme;

    final destinations = const [
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

    final chromeColor = Color.alphaBlend(
      GlassTokens.glassBg(scheme.brightness, strong: true),
      GlassTokens.canvas(scheme.brightness),
    );
    final showHeader = _navIndex == 0;

    final header = SizedBox(
      height: _chromeItemHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              '工作区',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            Row(
              children: [
                const Spacer(),
                if (_caps != null && wide)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: _EnvChip(caps: _caps!),
                  ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    final contentBody = IndexedStack(
      index: _navIndex == 1 && !_settingsVisited ? 0 : _navIndex,
      children: [
        _WorkspaceHub(
          greeting: _greeting(),
          caps: _caps,
          busy: _busy,
          error: _error,
          workspaces: _workspaces,
          titleFor: _workspaceTitle,
          subtitleFor: _workspaceSubtitle,
          onDismissError: () => setState(() => _error = null),
          onCreate: _busy || _caps?.available != true ? null : _createWorkspace,
          onOpen: _busy ? null : _openWorkspace,
          onDelete: _busy ? null : _destroyWorkspace,
          workspaceIcon: _workspaceIcon,
        ),
        if (_settingsVisited)
          SettingsScreen(
            embedded: true,
            workspaceResolver: _resolveWorkspaceForSmoke,
          )
        else
          const SizedBox.shrink(),
      ],
    );

    final mainColumn = Column(
      children: [
        if (showHeader) header,
        if (_busy && showHeader) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: wide
              ? ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(_chromeInnerRadius),
                  ),
                  child: ColoredBox(
                    color: GlassTokens.canvas(scheme.brightness),
                    child: contentBody,
                  ),
                )
              : contentBody,
        ),
      ],
    );

    return OffloadPermissionDialogHost(
      child: AmbientBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: wide
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: chromeColor),
                    Row(
                      children: [
                        SizedBox(
                          width: _chromeRailWidth,
                          child: Column(
                            children: [
                              SizedBox(
                                height: _chromeItemHeight,
                                child: Center(
                                  child: CircleAvatar(
                                    radius: 20,
                                    backgroundColor: scheme.primary,
                                    foregroundColor: scheme.onPrimary,
                                    child: const Icon(Icons.shield_outlined),
                                  ),
                                ),
                              ),
                              for (final (i, d) in destinations.indexed)
                                _HomeNavButton(
                                  height: _chromeItemHeight,
                                  selected: _navIndex == i,
                                  icon: d.icon,
                                  selectedIcon: d.selectedIcon ?? d.icon,
                                  label: d.label,
                                  onTap: () => _selectNav(i),
                                ),
                            ],
                          ),
                        ),
                        Expanded(child: mainColumn),
                      ],
                    ),
                  ],
                )
              : mainColumn,
          bottomNavigationBar: wide
              ? null
              : Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: GlassPanel(
                    borderRadius: 28,
                    tone: GlassTone.strong,
                    child: NavigationBar(
                      selectedIndex: _navIndex,
                      onDestinationSelected: _selectNav,
                      destinations: destinations,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _HomeNavButton extends StatelessWidget {
  const _HomeNavButton({
    required this.height,
    required this.selected,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onTap,
  });

  final double height;
  final bool selected;
  final Widget icon;
  final Widget selectedIcon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      width: double.infinity,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: selected
                    ? scheme.secondaryContainer.withValues(alpha: 0.85)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: IconTheme(
                  data: IconThemeData(
                    size: 24,
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  child: selected ? selectedIcon : icon,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ],
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

class _WorkspaceHub extends StatelessWidget {
  const _WorkspaceHub({
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
  final IconData Function(String) workspaceIcon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (error != null) ...[
              MaterialBanner(
                content: Text(error!),
                actions: [
                  TextButton(
                    onPressed: onDismissError,
                    child: const Text('关闭'),
                  ),
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
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: scheme.onPrimaryContainer),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '一个工作区 = 一套独立 Linux 环境',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: scheme.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '创建后即可在同一环境中开启多轮会话。',
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
            const SizedBox(height: 24),
            Text('全部工作区', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            if (workspaces.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  busy ? '正在检查环境…' : '还没有工作区。点上方「新建工作区」开始。',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
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
                      onOpen: onOpen == null ? null : () => onOpen!(e.value),
                      onDelete: onDelete == null
                          ? null
                          : () => onDelete!(e.value),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WorkspaceRow extends StatelessWidget {
  const _WorkspaceRow({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onOpen,
    required this.onDelete,
  });

  final String title;
  final String subtitle;
  final IconData icon;
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
              FilledButton.tonal(onPressed: onOpen, child: const Text('打开')),
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
