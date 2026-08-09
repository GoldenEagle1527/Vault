import 'package:flutter/material.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/screens/home_screen.dart';
import 'package:vault/theme/app_theme.dart';
import 'package:vault/theme/theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final themeController = ThemeController();
  await themeController.load();
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
