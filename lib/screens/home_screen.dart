import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/agent/workspace_mode.dart';
import 'package:vault/agent/workspace_store.dart';
import 'package:vault/permissions/active_workspace_holder.dart';
import 'package:vault/permissions/offload_permission_dialog.dart';
import 'package:vault/sandbox/android_keep_alive.dart';
import 'package:vault/sandbox/network_reachability.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/screens/agent_screen.dart';
import 'package:vault/screens/home/home_content.dart';
import 'package:vault/screens/home/home_view_model.dart';
import 'package:vault/screens/home/workspace_controller.dart';
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
  WorkspaceController? _controller;
  String? _initializationError;
  int _navIndex = 0;
  bool _settingsVisited = false;

  @override
  void initState() {
    super.initState();
    ActiveWorkspaceHolder.resolver = _resolveWorkspaceForSmoke;
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final metaDb = widget.metaDb ?? await VaultMetaDb.openDefault();
      final controller = WorkspaceController(
        provider: widget.provider,
        metaDb: metaDb,
        conversationStore:
            widget.conversationStore ?? ConversationStore(metaDb: metaDb),
        projectStore:
            widget.projectStore ??
            ProjectStore.fromProvider(widget.provider, metaDb: metaDb),
        workspaceStore: widget.workspaceStore ?? WorkspaceStore(metaDb: metaDb),
      );
      if (!mounted) return;
      setState(() => _controller = controller);
      await controller.refresh();
    } catch (e) {
      if (mounted) {
        setState(() => _initializationError = '初始化元数据库失败：$e');
      }
    }
  }

  Future<SandboxWorkspace?> _resolveWorkspaceForSmoke() async {
    final controller = _controller;
    if (controller == null ||
        controller.capabilities?.available != true ||
        controller.workspaces.isEmpty) {
      return null;
    }
    return widget.provider.attach(controller.workspaces.first.workspaceId);
  }

  Future<void> _createWorkspace() async {
    final controller = _controller;
    if (controller == null || !controller.capabilities!.available) return;
    final existingNames = controller.names.values.where(
      (name) => name.trim().isNotEmpty,
    );
    final typedName = await showNewWorkspaceDialog(
      context,
      existingNames: existingNames,
    );
    if (typedName == null || !mounted) return;
    final mode = await showWorkspaceModeDialog(context);
    if (mode == null || !mounted) return;
    final displayName = WorkspaceStore.allocateDisplayName(
      existingNames,
      base: typedName,
    );
    if (!await hasOutboundNetwork()) {
      controller.setError('当前无法联网，已取消初始化工作区。请连接网络后重试。');
      return;
    }
    if (!mounted) return;
    final id = const Uuid().v4().replaceAll('-', '').substring(0, 12);
    try {
      final workspace = await runWithWorkspaceInitDialog(
        context: context,
        action: (report) => controller.create(
          id: id,
          displayName: displayName,
          mode: mode,
          onProgress: report,
        ),
      );
      if (!mounted) return;
      await _openAgent(workspace, displayName, mode);
      await controller.refresh();
    } catch (_) {}
  }

  Future<void> _openWorkspace(HomeWorkspaceItemViewModel item) async {
    final controller = _controller!;
    try {
      final workspace = await controller.attach(item.info);
      if (!mounted) return;
      await _openAgent(
        workspace,
        resolvedWorkspaceName(item.info, controller.names),
        controller.modes[item.info.workspaceId] ?? WorkspaceMode.chat,
      );
      await controller.refresh();
    } catch (_) {}
  }

  Future<void> _openAgent(
    SandboxWorkspace workspace,
    String title,
    WorkspaceMode mode,
  ) async {
    final controller = _controller!;
    await AndroidKeepAlive.ensurePermissions(context);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AgentScreen(
          title: title,
          provider: widget.provider,
          workspace: workspace,
          conversationStore: controller.conversationStore,
          projectStore: controller.projectStore,
          mode: mode,
        ),
      ),
    );
  }

  Future<void> _deleteWorkspace(HomeWorkspaceItemViewModel item) async {
    final controller = _controller!;
    final destructive =
        controller.capabilities?.backend != SandboxBackend.proot;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除工作区？'),
        content: Text(
          destructive
              ? '将执行 wsl --unregister 卸载 ${item.title}，删除其磁盘文件与全部会话历史。'
                    '通常可回收约 1 GB 空间。'
              : '将删除工作区 ${item.title} 的独立空间、全部会话历史，并结束相关进程。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.destroy(item.info.workspaceId);
  }

  void _selectNavigation(int index) {
    setState(() {
      _navIndex = index;
      if (index == 1) _settingsVisited = true;
    });
  }

  @override
  void dispose() {
    if (identical(ActiveWorkspaceHolder.resolver, _resolveWorkspaceForSmoke)) {
      ActiveWorkspaceHolder.resolver = null;
    }
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Scaffold(
        body: _initializationError == null
            ? const Center(child: CircularProgressIndicator())
            : Center(child: Text(_initializationError!)),
      );
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _buildPage(
        buildHomeViewModel(
          capabilities: controller.capabilities,
          busy: controller.busy,
          error: controller.error,
          workspaces: controller.workspaces,
          summaries: controller.summaries,
          modes: controller.modes,
          names: controller.names,
        ),
      ),
    );
  }

  Widget _buildPage(HomeViewModel model) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
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
    final content = IndexedStack(
      index: _navIndex == 1 && !_settingsVisited ? 0 : _navIndex,
      children: [
        HomeContent(
          model: model,
          onDismissError: _controller!.dismissError,
          onCreate: model.canCreate ? _createWorkspace : null,
          onOpen: model.busy ? null : _openWorkspace,
          onDelete: model.busy ? null : _deleteWorkspace,
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
    final main = Column(
      children: [
        if (_navIndex == 0)
          SizedBox(
            height: 64,
            child: Row(
              children: [
                const Spacer(),
                Text('工作区', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (model.capabilities != null && wide)
                  HomeEnvironmentChip(model: model),
                IconButton(
                  tooltip: '刷新',
                  onPressed: model.busy ? null : _controller!.refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
        if (model.busy && _navIndex == 0)
          const LinearProgressIndicator(minHeight: 2),
        Expanded(child: content),
      ],
    );
    return OffloadPermissionDialogHost(
      child: AmbientBackdrop(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: wide
              ? Row(
                  children: [
                    ColoredBox(
                      color: GlassTokens.glassBg(
                        scheme.brightness,
                        strong: true,
                      ),
                      child: SizedBox(
                        width: 80,
                        child: Column(
                          children: [
                            const SizedBox(
                              height: 64,
                              child: Icon(Icons.shield_outlined),
                            ),
                            HomeRailButton(
                              selected: _navIndex == 0,
                              icon: Icons.workspaces_outlined,
                              label: '工作区',
                              onTap: () => _selectNavigation(0),
                            ),
                            HomeRailButton(
                              selected: _navIndex == 1,
                              icon: Icons.settings_outlined,
                              label: '设置',
                              onTap: () => _selectNavigation(1),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(child: main),
                  ],
                )
              : main,
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _navIndex,
                  onDestinationSelected: _selectNavigation,
                  destinations: destinations,
                ),
        ),
      ),
    );
  }
}
