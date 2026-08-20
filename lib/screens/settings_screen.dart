import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/diagnostics/vault_api_smoke.dart';
import 'package:vault/permissions/active_workspace_holder.dart';
import 'package:vault/permissions/offload_permission_manager.dart';
import 'package:vault/permissions/permission_models.dart';
import 'package:vault/permissions/permission_registry.dart';
import 'package:vault/sandbox/android_keep_alive.dart';
import 'package:vault/sandbox/desktop_keep_alive.dart';
import 'package:vault/sandbox/proot_host.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/widgets/appearance_sheet.dart';

class SettingsScreen extends StatefulWidget {
  SettingsScreen({
    super.key,
    AgentSettingsStore? store,
    OffloadPermissionManager? permissionManager,
    this.embedded = false,
    this.workspaceResolver,
  }) : store = store ?? AgentSettingsStore(),
       permissionManager =
           permissionManager ?? OffloadPermissionManager.instance;

  final AgentSettingsStore store;
  final OffloadPermissionManager permissionManager;

  /// When true, omit the scaffold AppBar (used as a home nav destination).
  final bool embedded;

  /// Optional injector for API smoke. Prefer [ActiveWorkspaceHolder].
  ///
  /// If null, falls back to [ActiveWorkspaceHolder.resolve].
  final Future<SandboxWorkspace?> Function()? workspaceResolver;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _baseCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  List<AgentSettings> _profiles = const [AgentSettings.defaults];
  String _activeId = AgentSettings.defaultProfileId;
  bool _loading = true;
  bool _saving = false;
  bool _obscureKey = true;
  String? _error;
  String? _savedHint;

  bool _onlyImplemented = true;
  bool _includeIntegrations = false;
  bool _smokeRunning = false;
  bool _permsReady = false;
  AndroidKeepAliveStatus? _keepAliveStatus;
  bool _keepAliveBusy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bundle = await widget.store.loadBundle();
      await widget.permissionManager.ensureLoaded();
      AndroidKeepAliveStatus? keepAlive;
      if (Platform.isAndroid) {
        keepAlive = await AndroidKeepAlive.status();
      }
      if (!mounted) return;
      _applyBundle(bundle);
      _permsReady = true;
      _keepAliveStatus = keepAlive;
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '加载设置失败：$e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _refreshKeepAliveStatus() async {
    if (!Platform.isAndroid) return;
    setState(() => _keepAliveBusy = true);
    try {
      final status = await AndroidKeepAlive.status();
      if (!mounted) return;
      setState(() => _keepAliveStatus = status);
    } finally {
      if (mounted) setState(() => _keepAliveBusy = false);
    }
  }

  Future<void> _requestKeepAlivePermissions() async {
    if (!Platform.isAndroid || !mounted) return;
    await AndroidKeepAlive.ensurePermissions(
      context,
      forceBatteryPrompt: true,
    );
    await _refreshKeepAliveStatus();
  }

  Future<void> _openBatterySettings() async {
    if (!Platform.isAndroid) return;
    await ProotHost.openBatteryOptimizationSettings();
    await _refreshKeepAliveStatus();
  }

  List<Widget> _keepAliveSection(ColorScheme scheme) {
    if (DesktopKeepAlive.supported) {
      return _desktopKeepAliveSection(scheme);
    }
    if (!Platform.isAndroid) return const [];
    final status = _keepAliveStatus;
    return [
      const SizedBox(height: 28),
      const Divider(),
      const SizedBox(height: 16),
      Text('Android 后台保活', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(
        '工作区、开发站点与 Agent 任务切到浏览器或锁屏时，依赖前台服务与电池优化豁免。',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 12),
      if (status == null)
        const LinearProgressIndicator(minHeight: 2)
      else
        ...androidKeepAliveStatusLines(status).map(
          (line) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '• $line',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.tonalIcon(
            onPressed: _keepAliveBusy ? null : _requestKeepAlivePermissions,
            icon: _keepAliveBusy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.notifications_active_outlined),
            label: const Text('请求通知与电池优化'),
          ),
          OutlinedButton.icon(
            onPressed: _keepAliveBusy ? null : _openBatterySettings,
            icon: const Icon(Icons.battery_saver_outlined),
            label: const Text('电池优化设置'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _desktopKeepAliveSection(ColorScheme scheme) {
    return [
      const SizedBox(height: 28),
      const Divider(),
      const SizedBox(height: 16),
      Text('桌面后台保活', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(
        '关闭窗口会最小化到系统托盘，工作区、开发站点与 Agent 任务继续运行。'
        '右键托盘图标可显示窗口、停止站点或退出。只有从托盘选择「退出 Vault」才会结束沙箱。',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 12),
      ...desktopKeepAliveStatusLines(siteRunning: false).map(
        (line) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            '• $line',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ),
    ];
  }

  void _applyBundle(AgentSettingsBundle bundle) {
    _profiles = bundle.profiles;
    _activeId = bundle.active.id;
    _fillFields(bundle.active);
  }

  void _fillFields(AgentSettings s) {
    _baseCtrl.text = s.apiBaseUrl;
    _keyCtrl.text = s.apiKey;
    _modelCtrl.text = s.model;
  }

  AgentSettings _currentProfile() {
    for (final p in _profiles) {
      if (p.id == _activeId) return p;
    }
    return _profiles.isEmpty ? AgentSettings.defaults : _profiles.first;
  }

  AgentSettings _draftFromFields() {
    final current = _currentProfile();
    return current.copyWith(
      apiBaseUrl: _baseCtrl.text.trim().isEmpty
          ? AgentSettings.defaults.apiBaseUrl
          : _baseCtrl.text.trim(),
      apiKey: _keyCtrl.text.trim(),
      model: _modelCtrl.text.trim().isEmpty
          ? AgentSettings.defaults.model
          : _modelCtrl.text.trim(),
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _savedHint = null;
    });
    try {
      await widget.store.save(_draftFromFields());
      final bundle = await widget.store.loadBundle();
      if (!mounted) return;
      setState(() {
        _applyBundle(bundle);
        _savedHint = '已保存（密钥仅存于安全存储）';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _switchProfile(String? id) async {
    if (id == null || id == _activeId || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
      _savedHint = null;
    });
    try {
      await widget.store.save(_draftFromFields());
      final bundle = await widget.store.selectProfile(id);
      if (!mounted) return;
      setState(() {
        _applyBundle(bundle);
        _savedHint = '已切换到「${bundle.active.displayName}」';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '切换失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addProfile() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
      _savedHint = null;
    });
    try {
      await widget.store.save(_draftFromFields());
      final bundle = await widget.store.addProfile();
      if (!mounted) return;
      setState(() {
        _applyBundle(bundle);
        _savedHint = '已新建「${bundle.active.displayName}」';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '新建失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _renameProfile() async {
    if (_saving) return;
    final current = _draftFromFields();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _RenameProfileDialog(initialName: current.displayName),
    );
    if (name == null || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
      _savedHint = null;
    });
    try {
      await widget.store.save(current.copyWith(name: name));
      final bundle = await widget.store.renameProfile(current.id, name);
      if (!mounted) return;
      setState(() {
        _applyBundle(bundle);
        _savedHint = '已重命名为「${bundle.active.displayName}」';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '重命名失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteProfile() async {
    if (_saving || _profiles.length <= 1) return;
    final current = _draftFromFields();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除配置'),
        content: Text('确定删除「${current.displayName}」？此操作不可撤销。'),
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
    if (ok != true || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
      _savedHint = null;
    });
    try {
      final bundle = await widget.store.deleteProfile(current.id);
      if (!mounted) return;
      setState(() {
        _applyBundle(bundle);
        _savedHint = '已删除，当前为「${bundle.active.displayName}」';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '删除失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<SandboxWorkspace?> _resolveWorkspace() async {
    final custom = widget.workspaceResolver;
    if (custom != null) {
      final ws = await custom();
      if (ws != null) return ws;
    }
    return ActiveWorkspaceHolder.resolve();
  }

  Future<void> _runApiSmoke() async {
    if (_smokeRunning) return;
    final workspace = await _resolveWorkspace();
    if (!mounted) return;
    if (workspace == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先创建并打开一个工作区')));
      return;
    }

    final ownedTemporarily = !identical(
      workspace,
      ActiveWorkspaceHolder.current,
    );

    setState(() => _smokeRunning = true);
    try {
      final report = await VaultApiSmokeRunner.run(
        workspace,
        includeIntegrations: _includeIntegrations,
        onlyImplemented: _onlyImplemented,
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (ctx) => _SmokeReportSheet(report: report),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('自检失败：$e')));
    } finally {
      if (ownedTemporarily) {
        try {
          await workspace.dispose();
        } catch (_) {}
      }
      if (mounted) setState(() => _smokeRunning = false);
    }
  }

  Future<void> _onLevelChanged(String id, PermissionLevel? level) async {
    if (level == null) return;
    await widget.permissionManager.setLevel(id, level);
    if (mounted) setState(() {});
  }

  Future<void> _onVaultConfigChanged(bool enabled) async {
    await widget.permissionManager.setVaultConfigEnabled(enabled);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (widget.embedded) ...[
                    Text(
                      '设置',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    '模型连接',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'OpenAI 兼容 API。可保存多套配置并用下拉切换。Base 需带 /v1；密钥仅存于安全存储。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: ValueKey('llm-profile-dropdown-$_activeId'),
                          initialValue: _profiles.any((p) => p.id == _activeId)
                              ? _activeId
                              : _profiles.first.id,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '配置文件',
                          ),
                          items: [
                            for (final p in _profiles)
                              DropdownMenuItem(
                                value: p.id,
                                child: Text(
                                  p.displayName,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _saving ? null : _switchProfile,
                        ),
                      ),
                      IconButton(
                        tooltip: '新建配置',
                        onPressed: _saving ? null : _addProfile,
                        icon: const Icon(Icons.add),
                      ),
                      IconButton(
                        tooltip: '重命名',
                        onPressed: _saving ? null : _renameProfile,
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: _profiles.length <= 1 ? '至少保留一套配置' : '删除',
                        onPressed: _saving || _profiles.length <= 1
                            ? null
                            : _deleteProfile,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _baseCtrl,
                    decoration: const InputDecoration(
                      labelText: 'API Base URL',
                      hintText: 'https://api.openai.com/v1',
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _keyCtrl,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      suffixIcon: IconButton(
                        tooltip: _obscureKey ? '显示' : '隐藏',
                        onPressed: () =>
                            setState(() => _obscureKey = !_obscureKey),
                        icon: Icon(
                          _obscureKey
                              ? Icons.visibility
                              : Icons.visibility_off,
                        ),
                      ),
                    ),
                    obscureText: _obscureKey,
                    autocorrect: false,
                    enableSuggestions: false,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _modelCtrl,
                    decoration: const InputDecoration(
                      labelText: '模型',
                      hintText: 'gpt-4o-mini',
                    ),
                    autocorrect: false,
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(color: scheme.error),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (_savedHint != null) ...[
                    Text(
                      _savedHint!,
                      style: TextStyle(color: scheme.primary),
                    ),
                    const SizedBox(height: 8),
                  ],
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save),
                    label: Text(_saving ? '保存中…' : '保存'),
                  ),
                  const SizedBox(height: 28),
                  const Divider(),
                  const SizedBox(height: 16),
                  Text('外观', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    '浅色、深色或跟随系统，并选择主题色。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const AppearanceControls(showHeader: false),
                  ..._keepAliveSection(scheme),
                  const SizedBox(height: 28),
                  const Divider(),
                  const SizedBox(height: 16),
                  Text('权限', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    '控制 guest 内 vault-* CLI 调用宿主能力时的默认策略。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (_permsReady) ...[
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('配置总开关（vault_config）'),
                      subtitle: const Text('关闭后拒绝全部 offload API'),
                      value: widget.permissionManager.vaultConfigEnabled,
                      onChanged: _onVaultConfigChanged,
                    ),
                    const SizedBox(height: 4),
                    ..._permissionTiles(),
                  ],
                  const SizedBox(height: 28),
                  const Divider(),
                  const SizedBox(height: 16),
                  Text('诊断', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    '运行 API 自检。原生桥尚未接入时部分失败属预期。',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: _smokeRunning ? null : _runApiSmoke,
                    icon: _smokeRunning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.health_and_safety_outlined),
                    label: Text(_smokeRunning ? '自检运行中…' : '运行全部 API 自检'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('仅测当前平台已实现项'),
                    subtitle: const Text('默认开启；桥接未标记前 Wave1 会显示为跳过'),
                    value: _onlyImplemented,
                    onChanged: _smokeRunning
                        ? null
                        : (v) => setState(() => _onlyImplemented = v ?? true),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('包含高危集成'),
                    subtitle: const Text('无障碍 / Shizuku（仅 Android）'),
                    value: _includeIntegrations,
                    onChanged: _smokeRunning
                        ? null
                        : (v) =>
                            setState(() => _includeIntegrations = v ?? false),
                  ),
                ],
              ),
            ),
          );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: body,
    );
  }

  List<Widget> _permissionTiles() {
    final tiles = <Widget>[];
    for (final info in PermissionRegistry.settingsVisible) {
      if ((info.id == 'a11y' || info.id == 'shizuku') && !Platform.isAndroid) {
        continue;
      }
      final level = widget.permissionManager.levelOf(info.id);
      tiles.add(
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(info.displayNameZh),
          subtitle: Text(
            info.cliName +
                (info.id == 'a11y' || info.id == 'shizuku'
                    ? ' · 仅 Android'
                    : ''),
          ),
          trailing: DropdownButton<PermissionLevel>(
            value: level,
            onChanged: (v) => _onLevelChanged(info.id, v),
            items: const [
              DropdownMenuItem(
                value: PermissionLevel.bypass,
                child: Text('Bypass'),
              ),
              DropdownMenuItem(
                value: PermissionLevel.askOnce,
                child: Text('每次询问'),
              ),
              DropdownMenuItem(
                value: PermissionLevel.notAllowed,
                child: Text('禁止'),
              ),
            ],
          ),
        ),
      );
    }
    return tiles;
  }
}

class _SmokeReportSheet extends StatelessWidget {
  const _SmokeReportSheet({required this.report});

  final VaultApiSmokeReport report;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.75;
    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'API 自检结果',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                '${report.platform} · ${report.appVersion} · '
                '工作区 ${report.workspaceId}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: report.results.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final r = report.results[i];
                  return ListTile(
                    dense: true,
                    leading: Icon(_iconFor(r.status)),
                    title: Text(
                      '${r.permission.displayNameZh}（${r.permission.cliName}）',
                    ),
                    subtitle: Text(r.message),
                    trailing: Text(_labelFor(r.status)),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        showDialog<void>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Markdown 报告'),
                            content: SingleChildScrollView(
                              child: SelectableText(report.toMarkdown()),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('关闭'),
                              ),
                            ],
                          ),
                        );
                      },
                      child: const Text('Markdown'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('关闭'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(VaultApiSmokeStatus s) {
    switch (s) {
      case VaultApiSmokeStatus.pass:
        return Icons.check_circle_outline;
      case VaultApiSmokeStatus.fail:
        return Icons.error_outline;
      case VaultApiSmokeStatus.skip:
        return Icons.skip_next;
      case VaultApiSmokeStatus.unsupported:
        return Icons.block;
    }
  }

  static String _labelFor(VaultApiSmokeStatus s) {
    switch (s) {
      case VaultApiSmokeStatus.pass:
        return '通过';
      case VaultApiSmokeStatus.fail:
        return '失败';
      case VaultApiSmokeStatus.skip:
        return '跳过';
      case VaultApiSmokeStatus.unsupported:
        return '不支持';
    }
  }
}

class _RenameProfileDialog extends StatefulWidget {
  const _RenameProfileDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameProfileDialog> createState() => _RenameProfileDialogState();
}

class _RenameProfileDialogState extends State<_RenameProfileDialog> {
  late final TextEditingController _nameCtrl;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _nameCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _nameCtrl.text.length,
      );
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名配置'),
      content: TextField(
        controller: _nameCtrl,
        focusNode: _focusNode,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '配置名称',
          border: OutlineInputBorder(),
        ),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
