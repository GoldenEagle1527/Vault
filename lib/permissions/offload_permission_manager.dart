import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vault/permissions/permission_models.dart';
import 'package:vault/permissions/permission_registry.dart';

/// Persists offload permission levels + vault_config master switch, and
/// mediates ASK_ONCE prompts for the current chat session.
///
/// Levels use [flutter_secure_storage] (already in the app for API keys).
/// Session grants/denials are in-memory only.
class OffloadPermissionManager {
  OffloadPermissionManager({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
          );

  static final OffloadPermissionManager instance = OffloadPermissionManager();

  static const _kStorageKey = 'vault.offload.permissions.v1';

  final FlutterSecureStorage _storage;

  final Map<String, PermissionLevel> _levels = {};
  final Map<String, Map<String, bool>> _sessionAllow = {};
  final Map<String, Map<String, bool>> _sessionDeny = {};

  bool _vaultConfigEnabled = true;
  bool _loaded = false;

  /// Latest pending ASK_ONCE request for the UI dialog, or null.
  final ValueNotifier<PendingPermissionRequest?> pendingRequest =
      ValueNotifier<PendingPermissionRequest?>(null);

  Completer<AskResponse>? _askCompleter;

  bool get isLoaded => _loaded;

  /// Master switch (`vault_config`). When false, all other offload APIs deny.
  bool get vaultConfigEnabled => _vaultConfigEnabled;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await load();
  }

  Future<void> load() async {
    final raw = await _storage.read(key: _kStorageKey);
    _levels.clear();
    for (final info in PermissionRegistry.all) {
      if (info.id == 'vault_config') continue;
      _levels[info.id] = info.defaultLevel;
    }
    _vaultConfigEnabled = true;

    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final levels = map['levels'];
        if (levels is Map) {
          levels.forEach((key, value) {
            final id = key.toString();
            if (id == 'vault_config') return;
            final parsed = _parseLevel(value?.toString());
            if (parsed != null && PermissionRegistry.byId(id) != null) {
              _levels[id] = parsed;
            }
          });
        }
        final cfg = map['vaultConfigEnabled'];
        if (cfg is bool) {
          _vaultConfigEnabled = cfg;
        } else if (cfg is String) {
          _vaultConfigEnabled = cfg.toLowerCase() != 'false';
        }
      } catch (_) {
        // Keep defaults on corrupt storage.
      }
    }
    _loaded = true;
  }

  PermissionLevel levelOf(String permissionId) {
    if (permissionId == 'vault_config') {
      return PermissionLevel.bypass;
    }
    return _levels[permissionId] ??
        PermissionRegistry.byId(permissionId)?.defaultLevel ??
        PermissionLevel.notAllowed;
  }

  Future<void> setLevel(String permissionId, PermissionLevel level) async {
    if (permissionId == 'vault_config') return;
    await ensureLoaded();
    _levels[permissionId] = level;
    await _persist();
  }

  Future<void> setVaultConfigEnabled(bool enabled) async {
    await ensureLoaded();
    _vaultConfigEnabled = enabled;
    await _persist();
  }

  /// Clear allow/deny remembered for [sessionId] (and cancel a matching ask).
  void clearSessionGrants(String sessionId) {
    _sessionAllow.remove(sessionId);
    _sessionDeny.remove(sessionId);
    final pending = pendingRequest.value;
    if (pending != null && pending.sessionId == sessionId) {
      _failPending(AskResponse.denySession);
    }
  }

  /// Gate for a vault-* call. Suspends when level is [PermissionLevel.askOnce]
  /// until [respondToPending] completes the dialog.
  Future<PermissionDecision> checkPermission(
    String permissionId, {
    required String sessionId,
  }) async {
    await ensureLoaded();

    if (permissionId == 'vault_config') {
      return _vaultConfigEnabled
          ? PermissionDecision.allowed
          : PermissionDecision.denied;
    }

    if (!_vaultConfigEnabled) {
      return PermissionDecision.denied;
    }

    final info = PermissionRegistry.byId(permissionId);
    if (info == null) {
      return PermissionDecision.denied;
    }

    final level = levelOf(permissionId);
    switch (level) {
      case PermissionLevel.bypass:
        return PermissionDecision.allowed;
      case PermissionLevel.notAllowed:
        return PermissionDecision.denied;
      case PermissionLevel.askOnce:
        final denied = _sessionDeny[sessionId]?[permissionId] == true;
        if (denied) return PermissionDecision.denied;
        final allowed = _sessionAllow[sessionId]?[permissionId] == true;
        if (allowed) return PermissionDecision.allowed;
        return _askUser(info, sessionId);
    }
  }

  Future<PermissionDecision> _askUser(
    VaultPermissionInfo info,
    String sessionId,
  ) async {
    // Serialize asks: wait out any existing prompt first.
    while (_askCompleter != null) {
      try {
        await _askCompleter!.future;
      } catch (_) {}
    }

    final completer = Completer<AskResponse>();
    _askCompleter = completer;
    pendingRequest.value = PendingPermissionRequest(
      permissionId: info.id,
      sessionId: sessionId,
      displayNameZh: info.displayNameZh,
      cliName: info.cliName,
    );

    try {
      final response = await completer.future;
      switch (response) {
        case AskResponse.allowSession:
          _sessionAllow.putIfAbsent(sessionId, () => {})[info.id] = true;
          return PermissionDecision.allowed;
        case AskResponse.allowOnce:
          return PermissionDecision.allowed;
        case AskResponse.denySession:
          _sessionDeny.putIfAbsent(sessionId, () => {})[info.id] = true;
          return PermissionDecision.denied;
      }
    } finally {
      if (identical(_askCompleter, completer)) {
        _askCompleter = null;
        pendingRequest.value = null;
      }
    }
  }

  /// Complete the current ASK dialog (no-op if none).
  void respondToPending(AskResponse response) {
    final c = _askCompleter;
    if (c == null || c.isCompleted) return;
    c.complete(response);
  }

  void _failPending(AskResponse response) {
    final c = _askCompleter;
    if (c != null && !c.isCompleted) {
      c.complete(response);
    }
    _askCompleter = null;
    pendingRequest.value = null;
  }

  Future<void> _persist() async {
    final levelsJson = <String, String>{};
    for (final e in _levels.entries) {
      levelsJson[e.key] = e.value.name;
    }
    final payload = jsonEncode({
      'levels': levelsJson,
      'vaultConfigEnabled': _vaultConfigEnabled,
    });
    await _storage.write(key: _kStorageKey, value: payload);
  }

  static PermissionLevel? _parseLevel(String? raw) {
    if (raw == null) return null;
    for (final v in PermissionLevel.values) {
      if (v.name == raw) return v;
    }
    // Accept plan-style UPPER_SNAKE aliases.
    switch (raw.toUpperCase()) {
      case 'BYPASS':
        return PermissionLevel.bypass;
      case 'ASK_ONCE':
      case 'ASKONCE':
        return PermissionLevel.askOnce;
      case 'NOT_ALLOWED':
      case 'NOTALLOWED':
        return PermissionLevel.notAllowed;
    }
    return null;
  }

  @visibleForTesting
  void resetForTest() {
    _levels.clear();
    _sessionAllow.clear();
    _sessionDeny.clear();
    _vaultConfigEnabled = true;
    _loaded = false;
    _failPending(AskResponse.denySession);
  }
}
