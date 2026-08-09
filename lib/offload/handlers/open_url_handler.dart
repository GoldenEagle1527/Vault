import 'dart:io';

import 'package:vault/offload/handlers/offload_handler.dart';
import 'package:vault/offload/offload_protocol.dart';

/// `vault-open` — open a URL with the Windows default handler.
///
/// Uses [Process] only inside the offload layer (not SandboxProvider).
class OpenUrlHandler implements OffloadHandler {
  @override
  String get permissionId => 'open_url';

  @override
  String get command => 'vault-open';

  static final _urlRe = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');

  @override
  Future<OffloadResponse> handle(OffloadRequest request) async {
    final args = request.args;
    final sub = args.isEmpty ? '' : args.first;

    if (sub == 'smoke') {
      const sample = 'https://example.com';
      if (!_urlRe.hasMatch(sample)) {
        return OffloadResponse.error(1, 'url validation failed');
      }
      // Do not force-open a browser during smoke; validate only.
      return OffloadResponse.ok('ok open_url');
    }

    final url = args.isEmpty ? '' : args.join(' ').trim();
    if (url.isEmpty) {
      return OffloadResponse.error(2, 'usage: vault-open <url>|smoke');
    }
    if (!_urlRe.hasMatch(url)) {
      return OffloadResponse.error(2, 'invalid url: $url');
    }

    try {
      // `start "" <url>` — empty title arg required when URL may be quoted.
      final result = await Process.run(
        'cmd',
        ['/c', 'start', '', url],
        runInShell: false,
      );
      if (result.exitCode != 0) {
        final err = '${result.stderr}'.trim();
        return OffloadResponse.error(
          result.exitCode == 0 ? 1 : result.exitCode,
          err.isEmpty ? 'failed to open url' : err,
        );
      }
      return OffloadResponse.ok('ok');
    } catch (e) {
      return OffloadResponse.error(1, 'open failed: $e');
    }
  }
}
