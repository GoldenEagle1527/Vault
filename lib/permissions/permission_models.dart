/// Permission grant persistence level for a Vault offload capability.
enum PermissionLevel {
  /// Always allow without prompting.
  bypass,

  /// Prompt once per chat session (then remember grant/deny for that session).
  askOnce,

  /// Always deny at the Dart gate (CLI should exit 126).
  notAllowed,
}

/// Settings / registry grouping for offload APIs.
enum PermissionCategory { privacy, host, media, system, integrations, config }

/// User response to an ASK_ONCE prompt.
enum AskResponse { allowSession, allowOnce, denySession }

/// Outcome of [OffloadPermissionManager.checkPermission].
enum PermissionDecision { allowed, denied }

/// Static metadata for one Vault offload permission / CLI.
class VaultPermissionInfo {
  const VaultPermissionInfo({
    required this.id,
    required this.cliName,
    required this.category,
    required this.defaultLevel,
    required this.showInSettings,
    required this.androidSupported,
    required this.windowsSupported,
    required this.displayNameZh,
    this.bridgeImplementedAndroid = false,
    this.bridgeImplementedWindows = false,
  });

  /// Stable id (e.g. `clipboard`).
  final String id;

  /// Guest CLI binary name (e.g. `vault-clipboard`).
  final String cliName;

  final PermissionCategory category;
  final PermissionLevel defaultLevel;

  /// Whether to show a level dropdown in Settings (vault_config uses a switch).
  final bool showInSettings;

  final bool androidSupported;
  final bool windowsSupported;

  /// Chinese label for Settings / ASK dialog.
  final String displayNameZh;

  /// Set true when the native bridge + guest CLI exist for Android.
  final bool bridgeImplementedAndroid;

  /// Set true when the native bridge + guest CLI exist for Windows.
  final bool bridgeImplementedWindows;

  bool supportedOn({required bool isAndroid, required bool isWindows}) {
    if (isAndroid) return androidSupported;
    if (isWindows) return windowsSupported;
    return false;
  }

  bool implementedOn({required bool isAndroid, required bool isWindows}) {
    if (isAndroid) return bridgeImplementedAndroid;
    if (isWindows) return bridgeImplementedWindows;
    return false;
  }
}

/// In-flight ASK_ONCE request waiting on UI.
class PendingPermissionRequest {
  PendingPermissionRequest({
    required this.permissionId,
    required this.sessionId,
    required this.displayNameZh,
    required this.cliName,
  });

  final String permissionId;
  final String sessionId;
  final String displayNameZh;
  final String cliName;
}
