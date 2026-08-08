import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// BYO LLM settings. API key is stored only in secure storage — never in
/// `sessions.json` or application logs.
class AgentSettings {
  const AgentSettings({
    required this.apiBaseUrl,
    required this.apiKey,
    required this.model,
  });

  final String apiBaseUrl;
  final String apiKey;
  final String model;

  bool get isConfigured =>
      apiKey.trim().isNotEmpty && model.trim().isNotEmpty;

  AgentSettings copyWith({
    String? apiBaseUrl,
    String? apiKey,
    String? model,
  }) {
    return AgentSettings(
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
    );
  }

  static const defaults = AgentSettings(
    apiBaseUrl: 'https://api.openai.com/v1',
    apiKey: '',
    model: 'gpt-4o-mini',
  );
}

class AgentSettingsStore {
  AgentSettingsStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  static const _kBaseUrl = 'vault.agent.api_base_url';
  static const _kApiKey = 'vault.agent.api_key';
  static const _kModel = 'vault.agent.model';

  final FlutterSecureStorage _storage;

  Future<AgentSettings> load() async {
    final base = await _storage.read(key: _kBaseUrl);
    final key = await _storage.read(key: _kApiKey);
    final model = await _storage.read(key: _kModel);
    return AgentSettings(
      apiBaseUrl: (base == null || base.trim().isEmpty)
          ? AgentSettings.defaults.apiBaseUrl
          : base.trim(),
      apiKey: key?.trim() ?? '',
      model: (model == null || model.trim().isEmpty)
          ? AgentSettings.defaults.model
          : model.trim(),
    );
  }

  Future<void> save(AgentSettings settings) async {
    await _storage.write(
      key: _kBaseUrl,
      value: settings.apiBaseUrl.trim(),
    );
    await _storage.write(key: _kApiKey, value: settings.apiKey.trim());
    await _storage.write(key: _kModel, value: settings.model.trim());
  }
}
