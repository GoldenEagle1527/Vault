import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:vault/offload/offload_host_server.dart';
import 'package:vault/permissions/active_workspace_holder.dart';
import 'package:vault/permissions/offload_permission_manager.dart';
import 'package:vault/sandbox/offload_host.dart';
import 'package:vault/sandbox/offload_permission_channel.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/screens/home_screen.dart';
import 'package:vault/theme/app_theme.dart';
import 'package:vault/theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final themeController = ThemeController();
  await themeController.load();
  try {
    await OffloadPermissionManager.instance.ensureLoaded();
  } catch (_) {
    // Secure storage may be unavailable in some test hosts.
  }
  // Android: Kotlin TCP bridge + Dart permission channel; Windows: Dart server.
  if (Platform.isAndroid) {
    // Handler must be registered before disabling Kotlin bypass.
    OffloadPermissionChannel.register();
    try {
      await OffloadHost.ensureStarted();
      await OffloadHost.setBypassAll(false);
    } catch (_) {
      // Plugin may be unavailable in tests; attach/create will retry.
    }
  } else if (Platform.isWindows) {
    try {
      await ensureOffloadHostServer();
    } catch (e, st) {
      stderr.writeln('OffloadHostServer start failed: $e\n$st');
    }
  }
  final provider = createSandboxProvider();
  runApp(VaultApp(provider: provider, themeController: themeController));
}

class VaultApp extends StatefulWidget {
  const VaultApp({
    super.key,
    required this.provider,
    required this.themeController,
    this.metaDb,
  });

  final SandboxProvider provider;
  final ThemeController themeController;
  final VaultMetaDb? metaDb;

  @override
  State<VaultApp> createState() => _VaultAppState();
}

class _VaultAppState extends State<VaultApp> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: _onExitRequested,
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  /// Windows: close the window → terminate Vault WSL distros before exit.
  Future<AppExitResponse> _onExitRequested() async {
    final open = ActiveWorkspaceHolder.current;
    ActiveWorkspaceHolder.current = null;
    try {
      await open?.dispose();
    } catch (e, st) {
      stderr.writeln('dispose open workspace on exit failed: $e\n$st');
    }
    try {
      await widget.provider.stopRunningGuests();
    } catch (e, st) {
      stderr.writeln('stopRunningGuests on exit failed: $e\n$st');
    }
    if (Platform.isWindows) {
      try {
        await OffloadHostServer.instance?.stop();
      } catch (e, st) {
        stderr.writeln('OffloadHostServer stop on exit failed: $e\n$st');
      }
    }
    return AppExitResponse.exit;
  }

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      controller: widget.themeController,
      child: ListenableBuilder(
        listenable: widget.themeController,
        builder: (context, _) {
          return MaterialApp(
            title: 'Vault',
            theme: AppTheme.light(widget.themeController.accent),
            darkTheme: AppTheme.dark(widget.themeController.accent),
            themeMode: widget.themeController.mode,
            home: HomeScreen(provider: widget.provider, metaDb: widget.metaDb),
          );
        },
      ),
    );
  }
}
