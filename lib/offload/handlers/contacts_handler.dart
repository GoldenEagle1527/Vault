import 'dart:convert';
import 'dart:io';

import 'package:vault/offload/handlers/offload_handler.dart';
import 'package:vault/offload/offload_protocol.dart';

/// `vault-contacts` — best-effort Windows contacts via Outlook COM / PowerShell.
///
/// When Outlook is absent, [smoke] returns exit 0 with `limited: true`.
class ContactsHandler implements OffloadHandler {
  ContactsHandler({this.maxList = 50});

  final int maxList;

  @override
  String get permissionId => 'contacts';

  @override
  String get command => 'vault-contacts';

  @override
  Future<OffloadResponse> handle(OffloadRequest request) async {
    final args = request.args;
    final sub = args.isEmpty ? 'list' : args.first;

    switch (sub) {
      case 'smoke':
        return _smoke();
      case 'list':
        return _list();
      default:
        return OffloadResponse.error(
          2,
          'usage: vault-contacts list|smoke',
        );
    }
  }

  Future<OffloadResponse> _smoke() async {
    if (!Platform.isWindows) {
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'limited': true,
          'note': 'Windows contacts COM not available on ${Platform.operatingSystem}',
        }),
      );
    }
    final result = await _listOutlookContacts(limit: 1);
    if (result['available'] == true) {
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'count': (result['items'] as List?)?.length ?? 0,
        }),
      );
    }
    return OffloadResponse.ok(
      jsonEncode({
        'ok': true,
        'limited': true,
        'note': result['note'] ?? 'Outlook contacts unavailable',
      }),
    );
  }

  Future<OffloadResponse> _list() async {
    if (!Platform.isWindows) {
      return OffloadResponse.unsupported(
        'unsupported_platform: contacts requires Windows',
      );
    }
    final result = await _listOutlookContacts(limit: maxList);
    if (result['available'] == true) {
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'count': (result['items'] as List?)?.length ?? 0,
          'items': result['items'] ?? [],
        }),
      );
    }
    return OffloadResponse.ok(
      jsonEncode({
        'ok': true,
        'limited': true,
        'items': <Map<String, dynamic>>[],
        'note': result['note'] ?? 'Outlook contacts unavailable',
      }),
    );
  }

  Future<Map<String, dynamic>> _listOutlookContacts({required int limit}) async {
    final script = '''
\$limit = $limit
try {
  \$ol = New-Object -ComObject Outlook.Application
  \$ns = \$ol.GetNamespace('MAPI')
  \$folder = \$ns.GetDefaultFolder(10)
  \$items = \$folder.Items
  \$out = @()
  \$i = 0
  foreach (\$it in \$items) {
    if (\$i -ge \$limit) { break }
    \$name = [string]\$it.FullName
    if ([string]::IsNullOrWhiteSpace(\$name)) { \$name = [string]\$it.CompanyName }
    \$email = ''
    try { \$email = [string]\$it.Email1Address } catch {}
    \$out += @{
      name = \$name
      email = \$email
      company = [string]\$it.CompanyName
    }
    \$i++
  }
  @{ available = \$true; items = \$out } | ConvertTo-Json -Compress -Depth 4
} catch {
  @{ available = \$false; note = \$_.Exception.Message; items = @() } | ConvertTo-Json -Compress
}
''';

    try {
      final proc = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
        runInShell: false,
      ).timeout(const Duration(seconds: 12));
      final stdout = '${proc.stdout}'.trim();
      if (stdout.isEmpty) {
        return {
          'available': false,
          'note': 'empty PowerShell contacts response (exit ${proc.exitCode})',
          'items': <Map<String, dynamic>>[],
        };
      }
      final decoded = jsonDecode(stdout);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return {
        'available': false,
        'note': 'unexpected contacts payload',
        'items': <Map<String, dynamic>>[],
      };
    } catch (e) {
      return {
        'available': false,
        'note': 'contacts probe failed: $e',
        'items': <Map<String, dynamic>>[],
      };
    }
  }
}
