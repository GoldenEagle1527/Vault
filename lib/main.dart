import 'package:flutter/material.dart';
import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/screens/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final provider = createSandboxProvider();
  runApp(VaultApp(provider: provider));
}

class VaultApp extends StatelessWidget {
  const VaultApp({super.key, required this.provider});

  final SandboxProvider provider;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vault',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1F6F5B),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(provider: provider),
    );
  }
}
