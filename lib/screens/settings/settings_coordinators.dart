import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:vault/diagnostics/vault_api_smoke.dart';
import 'package:vault/permissions/active_workspace_holder.dart';
import 'package:vault/permissions/offload_permission_manager.dart';
import 'package:vault/permissions/permission_models.dart';
import 'package:vault/sandbox/sandbox_models.dart';

class PermissionSettingsCoordinator extends ChangeNotifier {
  PermissionSettingsCoordinator(this.manager);

  final OffloadPermissionManager manager;
  bool ready = false;
  bool _disposed = false;
  int _generation = 0;

  Future<void> load() async {
    final generation = _generation;
    if (_disposed) return;
    await manager.ensureLoaded();
    if (!_isCurrent(generation)) return;
    ready = true;
    notifyListeners();
  }

  Future<void> setLevel(String id, PermissionLevel? level) async {
    if (level == null) return;
    final generation = _generation;
    if (_disposed) return;
    await manager.setLevel(id, level);
    if (_isCurrent(generation)) notifyListeners();
  }

  Future<void> setEnabled(bool enabled) async {
    final generation = _generation;
    if (_disposed) return;
    await manager.setVaultConfigEnabled(enabled);
    if (_isCurrent(generation)) notifyListeners();
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    super.dispose();
  }
}

typedef ApiSmokeRunner =
    Future<VaultApiSmokeReport> Function(
      SandboxWorkspace workspace, {
      bool includeIntegrations,
      bool onlyImplemented,
    });

class ApiSmokeCoordinator extends ChangeNotifier {
  ApiSmokeCoordinator({this.workspaceResolver, ApiSmokeRunner? runner})
    : _runner = runner ?? VaultApiSmokeRunner.run;

  final Future<SandboxWorkspace?> Function()? workspaceResolver;
  final ApiSmokeRunner _runner;
  bool onlyImplemented = true;
  bool includeIntegrations = false;
  bool running = false;
  bool _disposed = false;
  int _generation = 0;

  void setOnlyImplemented(bool value) {
    if (_disposed) return;
    onlyImplemented = value;
    notifyListeners();
  }

  void setIncludeIntegrations(bool value) {
    if (_disposed) return;
    includeIntegrations = value;
    notifyListeners();
  }

  Future<VaultApiSmokeReport?> run() async {
    if (running || _disposed) return null;
    final generation = _generation;
    final workspace =
        await workspaceResolver?.call() ??
        await ActiveWorkspaceHolder.resolve();
    if (workspace == null) return null;
    final ownedTemporarily = !identical(
      workspace,
      ActiveWorkspaceHolder.current,
    );
    if (!_isCurrent(generation)) {
      if (ownedTemporarily) await workspace.dispose();
      return null;
    }
    running = true;
    notifyListeners();
    try {
      return await _runner(
        workspace,
        includeIntegrations: includeIntegrations,
        onlyImplemented: onlyImplemented,
      );
    } finally {
      if (ownedTemporarily) {
        try {
          await workspace.dispose();
        } catch (_) {}
      }
      if (_isCurrent(generation)) {
        running = false;
        notifyListeners();
      }
    }
  }

  bool get supportsIntegrations => Platform.isAndroid;

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
