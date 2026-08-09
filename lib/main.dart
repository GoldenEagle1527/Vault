import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vault/offload/offload_host_server.dart';
import 'package:vault/permissions/offload_permission_manager.dart';
import 'package:vault/sandbox/offload_host.dart';
import 'package:vault/sandbox/offload_permission_channel.dart';
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

class VaultApp extends StatelessWidget {
  const VaultApp({
    super.key,
    required this.provider,
    required this.themeController,
  });

  final SandboxProvider provider;
  final ThemeController themeController;

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      controller: themeController,
      child: ListenableBuilder(
        listenable: themeController,
        builder: (context, _) {
          return MaterialApp(
            title: 'Vault',
            theme: AppTheme.light(themeController.accent),
            darkTheme: AppTheme.dark(themeController.accent),
            themeMode: themeController.mode,
            home: HomeScreen(provider: provider),
          );
        },
      ),
    );
  }
}
