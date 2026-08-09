import 'dart:convert';

/// Wire protocol for guest `vault-*` → host offload bridge.
///
/// Request: `{ "argv": [...], "cwd", "env", "sessionId" }`
/// Response: `{ "exitCode", "stdout" }`
/// Exit semantics: 126 permission_denied, 125 unsupported_platform, 127 unknown command.

const int kOffloadExitOk = 0;
const int kOffloadExitUnsupported = 125;
const int kOffloadExitPermissionDenied = 126;
const int kOffloadExitUnknownCommand = 127;

const String kVaultChatSessionIdEnv = 'VAULT_CHAT_SESSION_ID';
const String kOffloadGuestHostFile = '/etc/vault-offload.host';
const String kOffloadGuestPortFile = '/etc/vault-offload.port';

class OffloadRequest {
  const OffloadRequest({
    required this.argv,
    this.cwd = '',
    this.env = const {},
    this.sessionId,
  });

  final List<String> argv;
  final String cwd;
  final Map<String, String> env;
  final String? sessionId;

  /// Basename of argv[0], e.g. `vault-clipboard`.
  String get command {
    if (argv.isEmpty) return '';
    final raw = argv.first.replaceAll('\\', '/');
    final slash = raw.lastIndexOf('/');
    return slash >= 0 ? raw.substring(slash + 1) : raw;
  }

  List<String> get args =>
      argv.length <= 1 ? const [] : argv.sublist(1);

  String? get effectiveSessionId {
    final fromField = sessionId?.trim();
    if (fromField != null && fromField.isNotEmpty) return fromField;
    final fromEnv = env[kVaultChatSessionIdEnv]?.trim();
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    return null;
  }

  Map<String, dynamic> toJson() => {
        'argv': argv,
        'cwd': cwd,
        'env': env,
        'sessionId': sessionId,
      };

  static OffloadRequest fromJson(Map<String, dynamic> json) {
    final argvRaw = json['argv'];
    final argv = <String>[];
    if (argvRaw is List) {
      for (final e in argvRaw) {
        argv.add('$e');
      }
    }

    final envRaw = json['env'];
    final env = <String, String>{};
    if (envRaw is Map) {
      envRaw.forEach((k, v) {
        if (k == null) return;
        env['$k'] = v?.toString() ?? '';
      });
    }

    final session = json['sessionId']?.toString();
    return OffloadRequest(
      argv: argv,
      cwd: json['cwd']?.toString() ?? '',
      env: env,
      sessionId: session,
    );
  }

  static OffloadRequest decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('offload request must be a JSON object');
    }
    return fromJson(decoded);
  }

  String encode() => jsonEncode(toJson());
}

class OffloadResponse {
  const OffloadResponse({
    required this.exitCode,
    this.stdout = '',
  });

  final int exitCode;
  final String stdout;

  Map<String, dynamic> toJson() => {
        'exitCode': exitCode,
        'stdout': stdout,
      };

  static OffloadResponse fromJson(Map<String, dynamic> json) {
    final code = json['exitCode'];
    return OffloadResponse(
      exitCode: code is int ? code : int.tryParse('$code') ?? 1,
      stdout: json['stdout']?.toString() ?? '',
    );
  }

  static OffloadResponse decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('offload response must be a JSON object');
    }
    return fromJson(decoded);
  }

  String encode() => jsonEncode(toJson());

  static OffloadResponse ok([String stdout = '']) =>
      OffloadResponse(exitCode: kOffloadExitOk, stdout: stdout);

  static OffloadResponse permissionDenied([String message = 'permission_denied']) =>
      OffloadResponse(exitCode: kOffloadExitPermissionDenied, stdout: message);

  static OffloadResponse unsupported([String message = 'unsupported_platform']) =>
      OffloadResponse(exitCode: kOffloadExitUnsupported, stdout: message);

  static OffloadResponse unknownCommand([String message = 'unknown_command']) =>
      OffloadResponse(exitCode: kOffloadExitUnknownCommand, stdout: message);

  static OffloadResponse error(int exitCode, String message) =>
      OffloadResponse(exitCode: exitCode, stdout: message);
}
