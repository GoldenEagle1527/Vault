import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:vault/diagnostics/vault_api_smoke.dart';
import 'package:vault/permissions/permission_models.dart';
import 'package:vault/permissions/permission_registry.dart';
import 'package:vault/sandbox/android_keep_alive.dart';
import 'package:vault/sandbox/desktop_keep_alive.dart';
import 'package:vault/sandbox/proot_host.dart';
import 'package:vault/screens/settings/profile_controller.dart';
import 'package:vault/screens/settings/settings_coordinators.dart';

class ProfileSettingsSection extends StatelessWidget {
  const ProfileSettingsSection({
    super.key,
    required this.controller,
    required this.onRename,
    required this.onDelete,
  });

  final ProfileController controller;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('模型连接', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'OpenAI 兼容 API。可保存多套配置并用下拉切换。Base 需带 /v1；密钥仅存于安全存储。',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('llm-profile-dropdown-${controller.activeId}'),
                initialValue: controller.activeId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '配置文件'),
                items: [
                  for (final profile in controller.profiles)
                    DropdownMenuItem(
                      value: profile.id,
                      child: Text(
                        profile.displayName,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: controller.saving ? null : controller.switchTo,
              ),
            ),
            IconButton(
              tooltip: '新建配置',
              onPressed: controller.saving ? null : controller.add,
              icon: const Icon(Icons.add),
            ),
            IconButton(
              tooltip: '重命名',
              onPressed: controller.saving ? null : onRename,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: controller.profiles.length <= 1 ? '至少保留一套配置' : '删除',
              onPressed: controller.saving || controller.profiles.length <= 1
                  ? null
                  : onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: controller.baseController,
          decoration: const InputDecoration(
            labelText: 'API Base URL',
            hintText: 'https://api.openai.com/v1',
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: controller.keyController,
          decoration: InputDecoration(
            labelText: 'API Key',
            suffixIcon: IconButton(
              tooltip: controller.obscureKey ? '显示' : '隐藏',
              onPressed: controller.toggleKeyVisibility,
              icon: Icon(
                controller.obscureKey ? Icons.visibility : Icons.visibility_off,
              ),
            ),
          ),
          obscureText: controller.obscureKey,
          autocorrect: false,
          enableSuggestions: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: controller.modelController,
          decoration: const InputDecoration(
            labelText: '模型',
            hintText: 'gpt-4o-mini',
          ),
          autocorrect: false,
        ),
        const SizedBox(height: 16),
        if (controller.error != null) ...[
          Text(controller.error!, style: TextStyle(color: scheme.error)),
          const SizedBox(height: 8),
        ],
        if (controller.hint != null) ...[
          Text(controller.hint!, style: TextStyle(color: scheme.primary)),
          const SizedBox(height: 8),
        ],
        FilledButton.icon(
          onPressed: controller.saving ? null : controller.save,
          icon: controller.saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save),
          label: Text(controller.saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}

class PermissionSettingsSection extends StatelessWidget {
  const PermissionSettingsSection({super.key, required this.coordinator});

  final PermissionSettingsCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('权限', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          '控制 guest 内 vault-* CLI 调用宿主能力时的默认策略。',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        if (coordinator.ready) ...[
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('配置总开关（vault_config）'),
            subtitle: const Text('关闭后拒绝全部 offload API'),
            value: coordinator.manager.vaultConfigEnabled,
            onChanged: coordinator.setEnabled,
          ),
          for (final info in PermissionRegistry.settingsVisible)
            if (Platform.isAndroid ||
                (info.id != 'a11y' && info.id != 'shizuku'))
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
                  value: coordinator.manager.levelOf(info.id),
                  onChanged: (level) => coordinator.setLevel(info.id, level),
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
        ],
      ],
    );
  }
}

class ApiSmokeSection extends StatelessWidget {
  const ApiSmokeSection({
    super.key,
    required this.coordinator,
    required this.onRun,
  });

  final ApiSmokeCoordinator coordinator;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('诊断', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          '运行 API 自检。原生桥尚未接入时部分失败属预期。',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: coordinator.running ? null : onRun,
          icon: coordinator.running
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.health_and_safety_outlined),
          label: Text(coordinator.running ? '自检运行中…' : '运行全部 API 自检'),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('仅测当前平台已实现项'),
          subtitle: const Text('默认开启；桥接未标记前 Wave1 会显示为跳过'),
          value: coordinator.onlyImplemented,
          onChanged: coordinator.running
              ? null
              : (value) => coordinator.setOnlyImplemented(value ?? true),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('包含高危集成'),
          subtitle: const Text('无障碍 / Shizuku（仅 Android）'),
          value: coordinator.includeIntegrations,
          onChanged: coordinator.running
              ? null
              : (value) => coordinator.setIncludeIntegrations(value ?? false),
        ),
      ],
    );
  }
}

class KeepAliveSettingsSection extends StatelessWidget {
  const KeepAliveSettingsSection({
    super.key,
    required this.status,
    required this.busy,
    required this.onRequestPermissions,
    required this.onOpenBatterySettings,
  });

  final AndroidKeepAliveStatus? status;
  final bool busy;
  final VoidCallback onRequestPermissions;
  final VoidCallback onOpenBatterySettings;

  @override
  Widget build(BuildContext context) {
    if (DesktopKeepAlive.supported) {
      return _Section(
        title: '桌面后台保活',
        description:
            '关闭窗口会最小化到系统托盘，工作区、开发站点与 Agent 任务继续运行。'
            '右键托盘图标可显示窗口、停止站点或退出。',
        children: [
          for (final line in desktopKeepAliveStatusLines(
            siteRunning: DesktopKeepAlive.instance.siteName != null,
          ))
            Text('• $line'),
        ],
      );
    }
    if (!Platform.isAndroid) return const SizedBox.shrink();
    return _Section(
      title: 'Android 后台保活',
      description: '切到浏览器后靠通知保活并可停站。工作区与 Agent 任务同样依赖前台服务与电池优化豁免。',
      children: [
        if (status == null)
          const LinearProgressIndicator(minHeight: 2)
        else
          for (final line in androidKeepAliveStatusLines(status!))
            Text('• $line'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: busy ? null : onRequestPermissions,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('请求通知与电池优化'),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : onOpenBatterySettings,
              icon: const Icon(Icons.battery_saver_outlined),
              label: const Text('电池优化设置'),
            ),
          ],
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.description,
    required this.children,
  });

  final String title;
  final String description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      Text(description),
      const SizedBox(height: 12),
      ...children,
    ],
  );
}

class SmokeReportSheet extends StatelessWidget {
  const SmokeReportSheet({super.key, required this.report});

  final VaultApiSmokeReport report;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'API 自检结果',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: report.results.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final result = report.results[index];
                return ListTile(
                  title: Text(
                    '${result.permission.displayNameZh}（${result.permission.cliName}）',
                  ),
                  subtitle: Text(result.message),
                  trailing: Text(_statusLabel(result.status)),
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
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Markdown 报告'),
                        content: SingleChildScrollView(
                          child: SelectableText(report.toMarkdown()),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('Markdown'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context),
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

  String _statusLabel(VaultApiSmokeStatus status) => switch (status) {
    VaultApiSmokeStatus.pass => '通过',
    VaultApiSmokeStatus.fail => '失败',
    VaultApiSmokeStatus.skip => '跳过',
    VaultApiSmokeStatus.unsupported => '不支持',
  };
}

Future<String?> showRenameProfileDialog(
  BuildContext context,
  String initialName,
) async {
  final controller = TextEditingController(text: initialName);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('重命名配置'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '配置名称'),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result?.trim().isEmpty == true ? null : result;
}
