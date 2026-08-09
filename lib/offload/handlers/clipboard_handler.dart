import 'package:flutter/services.dart';
import 'package:vault/offload/handlers/offload_handler.dart';
import 'package:vault/offload/offload_protocol.dart';

/// `vault-clipboard` — get / set / smoke via Flutter [Clipboard] (works on Windows).
class ClipboardHandler implements OffloadHandler {
  @override
  String get permissionId => 'clipboard';

  @override
  String get command => 'vault-clipboard';

  @override
  Future<OffloadResponse> handle(OffloadRequest request) async {
    final args = request.args;
    final sub = args.isEmpty ? 'get' : args.first;

    switch (sub) {
      case 'smoke':
        const marker = 'vault-clipboard-smoke';
        await Clipboard.setData(const ClipboardData(text: marker));
        final got = await Clipboard.getData(Clipboard.kTextPlain);
        if (got?.text == marker) {
          return OffloadResponse.ok('ok clipboard');
        }
        return OffloadResponse.error(1, 'clipboard smoke mismatch');

      case 'get':
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        return OffloadResponse.ok(data?.text ?? '');

      case 'set':
        final text = args.length > 1
            ? args.sublist(1).join(' ')
            : '';
        await Clipboard.setData(ClipboardData(text: text));
        return OffloadResponse.ok('ok');

      default:
        return OffloadResponse.error(
          2,
          'usage: vault-clipboard get|set <text>|smoke',
        );
    }
  }
}
