import 'dart:convert';
import 'dart:io';

import 'package:vault/offload/handlers/offload_handler.dart';
import 'package:vault/offload/offload_protocol.dart';

/// `vault-calendar` — best-effort Windows calendar via Outlook COM / PowerShell.
///
/// When Outlook is absent, [smoke] returns exit 0 with `limited: true`.
class CalendarHandler implements OffloadHandler {
  CalendarHandler({this.maxList = 20});

  final int maxList;

  @override
  String get permissionId => 'calendar';

  @override
  String get command => 'vault-calendar';

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
          'usage: vault-calendar list|smoke',
        );
    }
  }

  Future<OffloadResponse> _smoke() async {
    if (!Platform.isWindows) {
      return OffloadResponse.ok(
        jsonEncode({
          'ok': true,
          'limited': true,
          'note': 'Windows calendar COM not available on ${Platform.operatingSystem}',
        }),
      );
    }
    final result = await _listOutlookEvents(limit: 1);
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
        'note': result['note'] ?? 'Outlook calendar unavailable',
      }),
    );
  }

  Future<OffloadResponse> _list() async {
    if (!Platform.isWindows) {
      return OffloadResponse.unsupported(
        'unsupported_platform: calendar requires Windows',
      );
    }
    final result = await _listOutlookEvents(limit: maxList);
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
        'note': result['note'] ?? 'Outlook calendar unavailable',
      }),
    );
  }

  Future<Map<String, dynamic>> _listOutlookEvents({required int limit}) async {
    final script = '''
\$limit = $limit
try {
  \$ol = New-Object -ComObject Outlook.Application
  \$ns = \$ol.GetNamespace('MAPI')
  \$cal = \$ns.GetDefaultFolder(9)
  \$items = \$cal.Items
  \$items.Sort('[Start]')
  \$items.IncludeRecurrences = \$true
  \$start = (Get-Date).AddDays(-1)
  \$end = (Get-Date).AddDays(14)
  \$filter = "[Start] >= '\$(\$start.ToString('g'))' AND [Start] <= '\$(\$end.ToString('g'))'"
  \$restricted = \$items.Restrict(\$filter)
  \$out = @()
  \$i = 0
  foreach (\$it in \$restricted) {
    if (\$i -ge \$limit) { break }
    \$out += @{
      subject = [string]\$it.Subject
      start = ([datetime]\$it.Start).ToUniversalTime().ToString('o')
      end = ([datetime]\$it.End).ToUniversalTime().ToString('o')
      location = [string]\$it.Location
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
          'note': 'empty PowerShell calendar response (exit ${proc.exitCode})',
          'items': <Map<String, dynamic>>[],
        };
      }
      final decoded = jsonDecode(stdout);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return {
        'available': false,
        'note': 'unexpected calendar payload',
        'items': <Map<String, dynamic>>[],
      };
    } catch (e) {
      return {
        'available': false,
        'note': 'calendar probe failed: $e',
        'items': <Map<String, dynamic>>[],
      };
    }
  }
}
