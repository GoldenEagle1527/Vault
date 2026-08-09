import 'package:flutter_test/flutter_test.dart';
import 'package:vault/diagnostics/vault_api_smoke.dart';
import 'package:vault/permissions/permission_models.dart';
import 'package:vault/permissions/permission_registry.dart';

void main() {
  test('registry contains expected ids and defaults', () {
    final ids = PermissionRegistry.all.map((p) => p.id).toSet();
    expect(
      ids,
      containsAll([
        'clipboard',
        'calendar',
        'contacts',
        'photos',
        'location',
        'host_files',
        'notification',
        'alarm',
        'device_info',
        'open_url',
        'weather',
        'speak',
        'speech',
        'player',
        'a11y',
        'shizuku',
        'vault_config',
      ]),
    );

    expect(
      PermissionRegistry.byId('location')!.defaultLevel,
      PermissionLevel.askOnce,
    );
    expect(
      PermissionRegistry.byId('a11y')!.defaultLevel,
      PermissionLevel.notAllowed,
    );
    expect(
      PermissionRegistry.byId('shizuku')!.defaultLevel,
      PermissionLevel.notAllowed,
    );
    expect(PermissionRegistry.byId('alarm')!.windowsSupported, isFalse);
    expect(PermissionRegistry.byId('player')!.windowsSupported, isFalse);
    expect(PermissionRegistry.byId('device_info')!.showInSettings, isFalse);
    expect(PermissionRegistry.byId('speak')!.showInSettings, isFalse);
  });

  test('Wave1 bridges are marked implemented on Android and Windows', () {
    for (final id in PermissionRegistry.wave1Ids) {
      final p = PermissionRegistry.byId(id)!;
      expect(p.bridgeImplementedAndroid, isTrue, reason: id);
      expect(p.bridgeImplementedWindows, isTrue, reason: id);
    }
  });

  test('Wave2 bridges are marked implemented on Android and Windows', () {
    for (final id in PermissionRegistry.wave2Ids) {
      final p = PermissionRegistry.byId(id)!;
      expect(p.bridgeImplementedAndroid, isTrue, reason: id);
      expect(p.bridgeImplementedWindows, isTrue, reason: id);
    }
  });

  test('Wave3 bridges are marked implemented on Android and Windows', () {
    expect(
      PermissionRegistry.wave3Ids,
      containsAll(['host_files', 'vault_config', 'speak', 'speech']),
    );
    for (final id in PermissionRegistry.wave3Ids) {
      final p = PermissionRegistry.byId(id)!;
      expect(p.bridgeImplementedAndroid, isTrue, reason: id);
      expect(p.bridgeImplementedWindows, isTrue, reason: id);
    }
    // player / alarm stay unimplemented on Windows (and not in wave3Ids).
    expect(PermissionRegistry.wave3Ids.contains('player'), isFalse);
    expect(PermissionRegistry.wave3Ids.contains('alarm'), isFalse);
    expect(
      PermissionRegistry.byId('player')!.bridgeImplementedWindows,
      isFalse,
    );
    expect(
      PermissionRegistry.byId('alarm')!.bridgeImplementedWindows,
      isFalse,
    );
  });

  test('Wave4 bridges are Android-only skeleton (not Windows)', () {
    expect(PermissionRegistry.wave4Ids, containsAll(['a11y', 'shizuku']));
    for (final id in PermissionRegistry.wave4Ids) {
      final p = PermissionRegistry.byId(id)!;
      expect(p.bridgeImplementedAndroid, isTrue, reason: id);
      expect(p.bridgeImplementedWindows, isFalse, reason: id);
      expect(p.windowsSupported, isFalse, reason: id);
      expect(p.defaultLevel, PermissionLevel.notAllowed, reason: id);
    }
  });

  test('smoke case builder respects onlyImplemented and integrations', () {
    final implementedIds = {
      ...PermissionRegistry.wave1Ids,
      ...PermissionRegistry.wave2Ids,
      ...PermissionRegistry.wave3Ids,
    };

    final waveAndroid = VaultApiSmokeRunner.buildCases(
      onlyImplemented: true,
      includeIntegrations: false,
      isAndroid: true,
      isWindows: false,
    );
    expect(
      waveAndroid.map((c) => c.permission.id).toSet(),
      implementedIds,
    );
    expect(
      waveAndroid.every((c) => c.command.contains('${c.permission.cliName} smoke')),
      isTrue,
    );

    final waveWindows = VaultApiSmokeRunner.buildCases(
      onlyImplemented: true,
      includeIntegrations: false,
      isAndroid: false,
      isWindows: true,
    );
    expect(
      waveWindows.map((c) => c.permission.id).toSet(),
      implementedIds,
    );

    final wave4Android = VaultApiSmokeRunner.buildCases(
      onlyImplemented: true,
      includeIntegrations: true,
      isAndroid: true,
      isWindows: false,
    );
    expect(
      wave4Android.map((c) => c.permission.id).toSet(),
      {...implementedIds, ...PermissionRegistry.wave4Ids},
    );

    final wave4Windows = VaultApiSmokeRunner.buildCases(
      onlyImplemented: true,
      includeIntegrations: true,
      isAndroid: false,
      isWindows: true,
    );
    expect(
      wave4Windows.map((c) => c.permission.id).toSet(),
      implementedIds,
    );
    expect(wave4Windows.any((c) => c.permission.id == 'a11y'), isFalse);

    final allAndroid = VaultApiSmokeRunner.buildCases(
      onlyImplemented: false,
      includeIntegrations: true,
      isAndroid: true,
      isWindows: false,
    );
    expect(allAndroid.any((c) => c.permission.id == 'a11y'), isTrue);
    expect(allAndroid.any((c) => c.permission.id == 'clipboard'), isTrue);

    final win = VaultApiSmokeRunner.buildCases(
      onlyImplemented: false,
      includeIntegrations: true,
      isAndroid: false,
      isWindows: true,
    );
    expect(win.any((c) => c.permission.id == 'alarm'), isFalse);
    expect(win.any((c) => c.permission.id == 'a11y'), isFalse);
  });
}
