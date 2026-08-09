import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vault/theme/app_theme.dart';

/// Persists MD3 theme mode + accent seed (non-secret prefs in secure storage).
class ThemeController extends ChangeNotifier {
  ThemeController({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  static const _kMode = 'vault.ui.theme_mode';
  static const _kAccent = 'vault.ui.accent';

  final FlutterSecureStorage _storage;

  ThemeMode _mode = ThemeMode.system;
  VaultAccent _accent = VaultAccent.blue;

  ThemeMode get mode => _mode;
  VaultAccent get accent => _accent;

  Future<void> load() async {
    final modeRaw = await _storage.read(key: _kMode);
    final accentRaw = await _storage.read(key: _kAccent);
    _mode = switch (modeRaw) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    _accent = VaultAccent.values.firstWhere(
      (a) => a.name == accentRaw,
      orElse: () => VaultAccent.blue,
    );
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    final value = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await _storage.write(key: _kMode, value: value);
  }

  Future<void> setAccent(VaultAccent accent) async {
    if (_accent == accent) return;
    _accent = accent;
    notifyListeners();
    await _storage.write(key: _kAccent, value: accent.name);
  }
}

class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    assert(scope != null, 'ThemeScope not found');
    return scope!.notifier!;
  }
}
