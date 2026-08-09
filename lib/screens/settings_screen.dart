import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/diagnostics/vault_api_smoke.dart';
import 'package:vault/permissions/active_workspace_holder.dart';
import 'package:vault/permissions/offload_permission_manager.dart';
import 'package:vault/permissions/permission_models.dart';
import 'package:vault/permissions/permission_registry.dart';
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
  bool _loading = true;
  bool _saving = false;
  bool _obscureKey = true;
  String? _error;
  String? _savedHint;

  bool _onlyImplemented = true;
  bool _includeIntegrations = false;
  bool _smokeRunning = false;
  bool _permsReady = false;

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
      final s = await widget.store.load();
      await widget.permissionManager.ensureLoaded();
      if (!mounted) return;
      _baseCtrl.text = s.apiBaseUrl;
      _keyCtrl.text = s.apiKey;
      _modelCtrl.text = s.model;
      _permsReady = true;
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '加载设置失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _savedHint = null;
    });
    try {
      final settings = AgentSettings(
        apiBaseUrl: _baseCtrl.text.trim().isEmpty
            ? AgentSettings.defaults.apiBaseUrl
            : _baseCtrl.text.trim(),
        apiKey: _keyCtrl.text.trim(),
        model: _modelCtrl.text.trim().isEmpty
            ? AgentSettings.defaults.model
            : _modelCtrl.text.trim(),
      );
      await widget.store.save(settings);
      if (!mounted) return;
      setState(() => _savedHint = '已保存（密钥仅存于安全存储）');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '保存失败：$e');
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
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (widget.embedded) ...[
                Text('设置', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
              ],
              Text(
                'OpenAI 兼容 API（BYO Key）。Base 需带 /v1，例如 https://apihub.example.com/v1。'
                '密钥不会写入 workspaces.json。',
                style: Theme.of(context).textTheme.bodyMedium,
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
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                    icon: Icon(
                      _obscureKey ? Icons.visibility : Icons.visibility_off,
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
              const SizedBox(height: 20),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 8),
              ],
              if (_savedHint != null) ...[
                Text(
                  _savedHint!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
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
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 8),
              Text('外观', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                '选择浅色、深色或跟随系统，并挑选主题色。',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              const AppearanceControls(showHeader: false),
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 8),
              Text('权限', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                '控制 guest 内 vault-* CLI 调用宿主能力时的默认策略。'
                '原生桥（Android Kotlin / Windows C++）尚未接入时，自检可能失败——属预期。',
                style: Theme.of(context).textTheme.bodyMedium,
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
                    : (v) => setState(() => _includeIntegrations = v ?? false),
              ),
              if (_permsReady) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('配置总开关（vault_config）'),
                  subtitle: const Text('关闭后拒绝全部 offload API'),
                  value: widget.permissionManager.vaultConfigEnabled,
                  onChanged: _onVaultConfigChanged,
                ),
                const SizedBox(height: 8),
                ..._permissionTiles(),
              ],
            ],
          );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('Agent 设置')),
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
