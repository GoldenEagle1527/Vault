import 'package:vault/permissions/permission_models.dart';

/// Canonical registry of Vault offload permissions (F8 / Native Offload).
///
/// Guest CLIs call into the host bridge; Dart gates by [PermissionLevel].
/// Wave1–3 bridges are shipped on Android + Windows; later waves flip
/// [VaultPermissionInfo.bridgeImplemented*].
abstract final class PermissionRegistry {
  static const List<VaultPermissionInfo> all = [
    VaultPermissionInfo(
      id: 'clipboard',
      cliName: 'vault-clipboard',
      category: PermissionCategory.privacy,
      defaultLevel: PermissionLevel.bypass,
      showInSettings: true,
      androidSupported: true,
      windowsSupported: true,
      bridgeImplementedAndroid: true,
      bridgeImplementedWindows: true,
      displayNameZh: '剪贴板',
    ),
    VaultPermissionInfo(
      id: 'calendar',
      cliName: 'vault-calendar',
      category: PermissionCategory.privacy,
      defaultLevel: PermissionLevel.bypass,
      showInSettings: true,
      androidSupported: true,
      windowsSupported: true,
      bridgeImplementedAndroid: true,
      bridgeImplementedWindows: true,
      displayNameZh: '日历',
    ),
    VaultPermissionInfo(
      id: 'contacts',
      cliName: 'vault-contacts',
      category: PermissionCategory.privacy,
      defaultLevel: PermissionLevel.bypass,
      showInSettings: true,
      androidSupported: true,
      windowsSupported: true,
      bridgeImplementedAndroid: true,
      bridgeImplementedWindows: true,
      displayNameZh: '通讯录',
    ),
    VaultPermissionInfo(
      id: 'photos',
      cliName: 'vault-photos',
      category: PermissionCategory.privacy,
      defaultLevel: PermissionLevel.bypass,
      showInSettings: true,
      androidSupported: true,
      windowsSupported: true,
      bridgeImplementedAndroid: true,
      bridgeImplementedWindows: true,
      displayNameZh: '相册',
    ),
    VaultPermissionInfo(
      id: 'location',
      cliName: 'vault-location',
      category: PermissionCategory.privacy,
      defaultLevel: PermissionLevel.askOnce,
      showInSettings: true,
      androidSupported: true,
      windowsSupported: true,
      bridgeImplementedAndroid: true,
      bridgeImplementedWindows: true,
      displayNameZh: '定位',
    ),
    VaultPermissionInfo(
      id: 'host_files',
      cliName: 'vault-host-files',
      category: PermissionCategory.host,
      defaultLevel: PermissionLevel.askOnce,
      showInSettings: true,
      androidSupported: true,
      windowsSupported: true,
      bridgeImplementedAndroid: true,
      bridgeImplementedWindows: true,
      displayNameZh: '宿主文件',
    ),
    VaultPermissionInfo(
      id: 'notification',
      cliName: 'vault-notification',
      category: PermissionCategory.system,
      defaultLevel: PermissionLevel.bypass,
      showInSettings: true,
      androidSupported: true,
      windowsSupported: true,
      bridgeImplementedAndroid: true,
      bridgeImplementedWindows: true,
      displayNameZh: '通知',
    ),
    VaultPermissionInfo(
      id: 'alarm',
      cliName: 'vault-alarm',
      category: PermissionCategory.system,
      defaultLevel: PermissionLevel.bypass,
      showInSettings: true,
      androidSupported: true,
      windowsSupported: false,
      displayNameZh: '闹钟',
    ),
    VaultPermissionInfo(
      id: 'device_info',
      cliName: 'vault-device',
      category: PermissionCategory.system,
      defaultLevel: PermissionLevel.bypass,
      showInSettings: false,
      androidSupported: true,
      windowsSupported: true,
      bridgeImplementedAndroid: true,
      bridgeImplementedWindows: true,
      displayNameZh: '设备信息',
    ),
    VaultPermissionInfo(
      id: 'open_url',
      cliName: 'vault-open',
      category: PermissionCategory.system,
      defaultLevel: PermissionLevel.bypass,
      showInSettings: false,
      androidSupported: true,
      windowsSupported: true,
      bridgeImplementedAndroid: true,
      bridgeImplementedWindows: true,
      displayNameZh: '打开链接',
    ),
    VaultPermissionInfo(
      id: 'weather',
      cliName: 'vault-weather',
      category: PermissionCategory.system,
      defaultLevel: PermissionLevel.bypass,
      showInSettings: false,
      androidSupported: true,
      windowsSupported: true,
      displayNameZh: '天气',
    ),
    // Media: hidden from Settings by default (still smoke-testable).
    VaultPermissionInfo(
      id: 'speak',
      cliName: 'vault-speak',
      category: PermissionCategory.media,
      defaultLevel: PermissionLevel.bypass,
      showInSettings: false,
      androidSupported: true,
      windowsSupported: true,
      bridgeImplementedAndroid: true,
      bridgeImplementedWindows: true,
      displayNameZh: '语音朗读',
    ),
    VaultPermissionInfo(
      id: 'speech',
      cliName: 'vault-speech',
      category: PermissionCategory.media,
      defaultLevel: PermissionLevel.bypass,
      showInSettings: false,
      androidSupported: true,
      windowsSupported: true,
      bridgeImplementedAndroid: true,
      bridgeImplementedWindows: true,
      displayNameZh: '语音识别',
    ),
    VaultPermissionInfo(
      id: 'player',
      cliName: 'vault-player',
      category: PermissionCategory.media,
      defaultLevel: PermissionLevel.bypass,
      showInSettings: false,
      androidSupported: true,
      windowsSupported: false,
      displayNameZh: '媒体播放',
    ),
    VaultPermissionInfo(
      id: 'a11y',
      cliName: 'vault-a11y',
      category: PermissionCategory.integrations,
      defaultLevel: PermissionLevel.notAllowed,
      showInSettings: true,
      androidSupported: true,
      windowsSupported: false,
      bridgeImplementedAndroid: true,
      displayNameZh: '无障碍',
    ),
    VaultPermissionInfo(
      id: 'shizuku',
      cliName: 'vault-shizuku',
      category: PermissionCategory.integrations,
      defaultLevel: PermissionLevel.notAllowed,
      showInSettings: true,
      androidSupported: true,
      windowsSupported: false,
      bridgeImplementedAndroid: true,
      displayNameZh: 'Shizuku',
    ),
    // Master switch row — level unused; see OffloadPermissionManager.vaultConfigEnabled.
    VaultPermissionInfo(
      id: 'vault_config',
      cliName: 'vault-config',
      category: PermissionCategory.config,
      defaultLevel: PermissionLevel.bypass,
      showInSettings: true,
      androidSupported: true,
      windowsSupported: true,
      bridgeImplementedAndroid: true,
      bridgeImplementedWindows: true,
      displayNameZh: '配置总开关',
    ),
  ];

  /// Wave 1 CLIs (Android Kotlin + Windows Dart bridges shipped).
  static const wave1Ids = {
    'clipboard',
    'device_info',
    'open_url',
    'notification',
  };

  /// Wave 2 CLIs (Android Kotlin + Windows bridges shipped / landing).
  static const wave2Ids = {
    'calendar',
    'contacts',
    'photos',
    'location',
  };

  /// Wave 3 CLIs (shared wiring; `player`/`alarm` stay platform-deferred).
  static const wave3Ids = {
    'host_files',
    'vault_config',
    'speak',
    'speech',
  };

  /// Wave 4 CLIs (Android-only integrations skeleton; Windows stays unsupported).
  static const wave4Ids = {
    'a11y',
    'shizuku',
  };

  static VaultPermissionInfo? byId(String id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  static VaultPermissionInfo? byCliName(String cliName) {
    for (final p in all) {
      if (p.cliName == cliName) return p;
    }
    return null;
  }

  static List<VaultPermissionInfo> get settingsVisible =>
      all.where((p) => p.showInSettings && p.id != 'vault_config').toList();
}
