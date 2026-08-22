import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/permissions/offload_permission_manager.dart';
import 'package:vault/sandbox/android_keep_alive.dart';
import 'package:vault/sandbox/proot_host.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/screens/settings/profile_controller.dart';
import 'package:vault/screens/settings/settings_coordinators.dart';
import 'package:vault/screens/settings/settings_sections.dart';
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
  final bool embedded;
  final Future<SandboxWorkspace?> Function()? workspaceResolver;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final ProfileController _profiles;
  late final PermissionSettingsCoordinator _permissions;
  late final ApiSmokeCoordinator _smoke;
  AndroidKeepAliveStatus? _keepAliveStatus;
  bool _keepAliveBusy = false;

  @override
  void initState() {
    super.initState();
    _profiles = ProfileController(widget.store);
    _permissions = PermissionSettingsCoordinator(widget.permissionManager);
    _smoke = ApiSmokeCoordinator(workspaceResolver: widget.workspaceResolver);
    unawaited(_profiles.load());
    unawaited(_permissions.load());
    unawaited(_refreshKeepAlive());
  }

  Future<void> _refreshKeepAlive() async {
    if (!Platform.isAndroid) return;
    final status = await AndroidKeepAlive.status();
    if (mounted) setState(() => _keepAliveStatus = status);
  }

  Future<void> _requestKeepAlive() async {
    if (!Platform.isAndroid) return;
    setState(() => _keepAliveBusy = true);
    await AndroidKeepAlive.ensurePermissions(context, forceBatteryPrompt: true);
    await _refreshKeepAlive();
    if (mounted) setState(() => _keepAliveBusy = false);
  }

  Future<void> _openBatterySettings() async {
    await ProotHost.openBatteryOptimizationSettings();
    await _refreshKeepAlive();
  }

  Future<void> _renameProfile() async {
    final name = await showRenameProfileDialog(
      context,
      _profiles.draft.displayName,
    );
    if (name != null) await _profiles.rename(name);
  }

  Future<void> _deleteProfile() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除配置'),
        content: Text('确定删除「${_profiles.draft.displayName}」？此操作不可撤销。'),
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
    if (confirmed == true) await _profiles.delete();
  }

  Future<void> _runSmoke() async {
    try {
      final report = await _smoke.run();
      if (!mounted) return;
      if (report == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先创建并打开一个工作区')));
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => SmokeReportSheet(report: report),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('自检失败：$e')));
      }
    }
  }

  @override
  void dispose() {
    _profiles.dispose();
    _permissions.dispose();
    _smoke.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = ListenableBuilder(
      listenable: Listenable.merge([_profiles, _permissions, _smoke]),
      builder: (context, _) {
        if (_profiles.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (widget.embedded) ...[
                  Text('设置', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 16),
                ],
                ProfileSettingsSection(
                  controller: _profiles,
                  onRename: _renameProfile,
                  onDelete: _deleteProfile,
                ),
                const _Divider(),
                Text('外观', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                const AppearanceControls(showHeader: false),
                const _Divider(),
                KeepAliveSettingsSection(
                  status: _keepAliveStatus,
                  busy: _keepAliveBusy,
                  onRequestPermissions: _requestKeepAlive,
                  onOpenBatterySettings: _openBatterySettings,
                ),
                const _Divider(),
                PermissionSettingsSection(coordinator: _permissions),
                const _Divider(),
                ApiSmokeSection(coordinator: _smoke, onRun: _runSmoke),
              ],
            ),
          ),
        );
      },
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: body,
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 20),
    child: Divider(),
  );
}
