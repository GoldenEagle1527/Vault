import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// One named BYO LLM connection (API base / key / model).
///
/// API keys live only in secure storage — never in `workspaces.json` or logs.
class AgentSettings {
  const AgentSettings({
    this.id = defaultProfileId,
    this.name = defaultProfileName,
    required this.apiBaseUrl,
    required this.apiKey,
    required this.model,
  });

  static const defaultProfileId = 'default';
  static const defaultProfileName = '默认';

  final String id;
  final String name;
  final String apiBaseUrl;
  final String apiKey;
  final String model;

  bool get isConfigured => apiKey.trim().isNotEmpty && model.trim().isNotEmpty;

  String get displayName {
    final n = name.trim();
    return n.isEmpty ? defaultProfileName : n;
  }

  AgentSettings copyWith({
    String? id,
    String? name,
    String? apiBaseUrl,
    String? apiKey,
    String? model,
  }) {
    return AgentSettings(
      id: id ?? this.id,
      name: name ?? this.name,
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'apiBaseUrl': apiBaseUrl,
    'apiKey': apiKey,
    'model': model,
  };

  factory AgentSettings.fromJson(Map<String, dynamic> json) {
    return AgentSettings(
      id: (json['id'] as String?)?.trim().isNotEmpty == true
          ? (json['id'] as String).trim()
          : defaultProfileId,
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : defaultProfileName,
      apiBaseUrl: (json['apiBaseUrl'] as String?)?.trim().isNotEmpty == true
          ? (json['apiBaseUrl'] as String).trim()
          : defaults.apiBaseUrl,
      apiKey: (json['apiKey'] as String?)?.trim() ?? '',
      model: (json['model'] as String?)?.trim().isNotEmpty == true
          ? (json['model'] as String).trim()
          : defaults.model,
    );
  }

  static const defaults = AgentSettings(
    id: defaultProfileId,
    name: defaultProfileName,
    apiBaseUrl: 'https://api.openai.com/v1',
    apiKey: '',
    model: 'gpt-4o-mini',
  );
}

/// All saved LLM profiles plus which one is currently selected.
class AgentSettingsBundle {
  const AgentSettingsBundle({required this.profiles, required this.activeId});

  final List<AgentSettings> profiles;
  final String activeId;

  AgentSettings get active {
    for (final p in profiles) {
      if (p.id == activeId) return p;
    }
    return profiles.isEmpty ? AgentSettings.defaults : profiles.first;
  }

  AgentSettingsBundle copyWith({
    List<AgentSettings>? profiles,
    String? activeId,
  }) {
    return AgentSettingsBundle(
      profiles: profiles ?? this.profiles,
      activeId: activeId ?? this.activeId,
    );
  }

  static AgentSettingsBundle get empty => AgentSettingsBundle(
    profiles: const [AgentSettings.defaults],
    activeId: AgentSettings.defaultProfileId,
  );
}

/// Minimal key/value backend so tests can avoid [FlutterSecureStorage].
abstract class AgentSettingsKv {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemoryAgentSettingsKv implements AgentSettingsKv {
  MemoryAgentSettingsKv([Map<String, String>? seed]) : _data = {...?seed};

  final Map<String, String> _data;

  Map<String, String> get snapshot => Map.unmodifiable(_data);

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }
}

class FlutterSecureAgentSettingsKv implements AgentSettingsKv {
  FlutterSecureAgentSettingsKv(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class AgentSettingsStore {
  AgentSettingsStore({FlutterSecureStorage? storage, AgentSettingsKv? kv})
    : _kv =
          kv ??
          FlutterSecureAgentSettingsKv(
            storage ??
                const FlutterSecureStorage(
                  aOptions: AndroidOptions(encryptedSharedPreferences: true),
                ),
          );

  static const _kBaseUrl = 'vault.agent.api_base_url';
  static const _kApiKey = 'vault.agent.api_key';
  static const _kModel = 'vault.agent.model';
  static const _kProfiles = 'vault.agent.profiles';
  static const _uuid = Uuid();

  final AgentSettingsKv _kv;

  /// Active profile — used by the agent runtime and `vault-config get`.
  Future<AgentSettings> load() async {
    final bundle = await loadBundle();
    return bundle.active;
  }

  Future<AgentSettingsBundle> loadBundle() async {
    final raw = await _kv.read(_kProfiles);
    if (raw != null && raw.trim().isNotEmpty) {
      final parsed = _parseBundle(raw);
      if (parsed != null) return parsed;
    }
    return _migrateLegacy();
  }

  /// Updates the active profile (or the profile whose [AgentSettings.id] matches).
  Future<void> save(AgentSettings settings) async {
    final bundle = await loadBundle();
    final id = settings.id.trim().isEmpty
        ? bundle.activeId
        : settings.id.trim();
    final next = settings.copyWith(id: id);
    final profiles = [...bundle.profiles];
    final index = profiles.indexWhere((p) => p.id == id);
    if (index < 0) {
      profiles.add(next);
    } else {
      profiles[index] = next;
    }
    await _persist(AgentSettingsBundle(profiles: profiles, activeId: id));
  }

  Future<void> saveBundle(AgentSettingsBundle bundle) => _persist(bundle);

  Future<AgentSettingsBundle> selectProfile(String id) async {
    final bundle = await loadBundle();
    final exists = bundle.profiles.any((p) => p.id == id);
    if (!exists) return bundle;
    final next = bundle.copyWith(activeId: id);
    await _persist(next);
    return next;
  }

  Future<AgentSettingsBundle> addProfile({String? name}) async {
    final bundle = await loadBundle();
    final profile = AgentSettings(
      id: _newId(),
      name: _uniqueName(bundle.profiles, name),
      apiBaseUrl: AgentSettings.defaults.apiBaseUrl,
      apiKey: '',
      model: AgentSettings.defaults.model,
    );
    final next = AgentSettingsBundle(
      profiles: [...bundle.profiles, profile],
      activeId: profile.id,
    );
    await _persist(next);
    return next;
  }

  Future<AgentSettingsBundle> renameProfile(String id, String name) async {
    final bundle = await loadBundle();
    final trimmed = name.trim();
    if (trimmed.isEmpty) return bundle;
    final profiles = [
      for (final p in bundle.profiles)
        if (p.id == id) p.copyWith(name: trimmed) else p,
    ];
    final next = bundle.copyWith(profiles: profiles);
    await _persist(next);
    return next;
  }

  /// Removes [id]. The last remaining profile cannot be deleted.
  Future<AgentSettingsBundle> deleteProfile(String id) async {
    final bundle = await loadBundle();
    if (bundle.profiles.length <= 1) return bundle;
    final profiles = bundle.profiles.where((p) => p.id != id).toList();
    if (profiles.length == bundle.profiles.length) return bundle;
    final activeId = bundle.activeId == id
        ? profiles.first.id
        : bundle.activeId;
    final next = AgentSettingsBundle(profiles: profiles, activeId: activeId);
    await _persist(next);
    return next;
  }

  Future<void> _persist(AgentSettingsBundle bundle) async {
    final profiles = bundle.profiles.isEmpty
        ? const [AgentSettings.defaults]
        : bundle.profiles;
    final activeId = profiles.any((p) => p.id == bundle.activeId)
        ? bundle.activeId
        : profiles.first.id;
    final active = profiles.firstWhere((p) => p.id == activeId);
    await _kv.write(
      _kProfiles,
      jsonEncode({
        'activeId': activeId,
        'profiles': [for (final p in profiles) p.toJson()],
      }),
    );
    await _kv.write(_kBaseUrl, active.apiBaseUrl.trim());
    await _kv.write(_kApiKey, active.apiKey.trim());
    await _kv.write(_kModel, active.model.trim());
  }

  Future<AgentSettingsBundle> _migrateLegacy() async {
    final base = await _kv.read(_kBaseUrl);
    final key = await _kv.read(_kApiKey);
    final model = await _kv.read(_kModel);
    final profile = AgentSettings(
      id: AgentSettings.defaultProfileId,
      name: AgentSettings.defaultProfileName,
      apiBaseUrl: (base == null || base.trim().isEmpty)
          ? AgentSettings.defaults.apiBaseUrl
          : base.trim(),
      apiKey: key?.trim() ?? '',
      model: (model == null || model.trim().isEmpty)
          ? AgentSettings.defaults.model
          : model.trim(),
    );
    final bundle = AgentSettingsBundle(
      profiles: [profile],
      activeId: profile.id,
    );
    final hasLegacy =
        (base != null && base.trim().isNotEmpty) ||
        (key != null && key.trim().isNotEmpty) ||
        (model != null && model.trim().isNotEmpty);
    if (hasLegacy) {
      await _persist(bundle);
    }
    return bundle;
  }

  AgentSettingsBundle? _parseBundle(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final list = map['profiles'];
      if (list is! List || list.isEmpty) return null;
      final profiles = <AgentSettings>[];
      final seen = <String>{};
      for (final item in list) {
        if (item is! Map) continue;
        var profile = AgentSettings.fromJson(Map<String, dynamic>.from(item));
        if (seen.contains(profile.id)) {
          profile = profile.copyWith(id: _newId());
        }
        seen.add(profile.id);
        profiles.add(profile);
      }
      if (profiles.isEmpty) return null;
      final activeId = (map['activeId'] as String?)?.trim();
      return AgentSettingsBundle(
        profiles: profiles,
        activeId:
            (activeId != null &&
                activeId.isNotEmpty &&
                profiles.any((p) => p.id == activeId))
            ? activeId
            : profiles.first.id,
      );
    } catch (_) {
      return null;
    }
  }

  static String _newId() => _uuid.v4().replaceAll('-', '').substring(0, 12);

  static String _uniqueName(List<AgentSettings> profiles, String? requested) {
    final taken = {for (final p in profiles) p.displayName};
    final base = (requested == null || requested.trim().isEmpty)
        ? '配置 ${profiles.length + 1}'
        : requested.trim();
    if (!taken.contains(base)) return base;
    var n = 2;
    while (taken.contains('$base $n')) {
      n++;
    }
    return '$base $n';
  }
}
