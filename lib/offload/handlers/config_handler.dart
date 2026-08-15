import 'dart:convert';

import 'package:vault/agent/agent_settings.dart';
import 'package:vault/offload/handlers/offload_handler.dart';
import 'package:vault/offload/offload_protocol.dart';
import 'package:vault/permissions/offload_permission_manager.dart';

/// `vault-config` — Offload master-switch status + non-secret agent settings.
///
/// Writes (set provider / API key / model via this CLI) are intentionally
/// skipped in Wave3 Windows; mutate settings through the Vault Settings UI /
/// [AgentSettingsStore.save] instead. This handler is read-only.
class ConfigHandler implements OffloadHandler {
  ConfigHandler({
    OffloadPermissionManager? permissionManager,
    AgentSettingsStore? settingsStore,
  })  : _permissionManager =
            permissionManager ?? OffloadPermissionManager.instance,
        _settingsStore = settingsStore ?? AgentSettingsStore();

  final OffloadPermissionManager _permissionManager;
  final AgentSettingsStore _settingsStore;

  @override
  String get permissionId => 'vault_config';

  @override
  String get command => 'vault-config';

  @override
  Future<OffloadResponse> handle(OffloadRequest request) async {
    final args = request.args;
    final sub = args.isEmpty ? 'status' : args.first;

    switch (sub) {
      case 'smoke':
      case 'status':
        return _status();
      case 'get':
        return _get();
      default:
        return OffloadResponse.error(
          2,
          'usage: vault-config smoke|status|get',
        );
    }
  }

  Future<OffloadResponse> _status() async {
    await _permissionManager.ensureLoaded();
    return OffloadResponse.ok(
      jsonEncode({
        'ok': true,
        'vaultConfigEnabled': _permissionManager.vaultConfigEnabled,
      }),
    );
  }

  Future<OffloadResponse> _get() async {
    await _permissionManager.ensureLoaded();
    final settings = await _settingsStore.load();
    final key = settings.apiKey.trim();
    // Never return API key plaintext — only presence + redacted placeholder.
    return OffloadResponse.ok(
      jsonEncode({
        'ok': true,
        'vaultConfigEnabled': _permissionManager.vaultConfigEnabled,
        'profileId': settings.id,
        'profileName': settings.displayName,
        'apiBaseUrl': settings.apiBaseUrl,
        'model': settings.model,
        'apiKeyConfigured': key.isNotEmpty,
        'apiKey': key.isEmpty ? '' : '***',
        'isConfigured': settings.isConfigured,
      }),
    );
  }
}
