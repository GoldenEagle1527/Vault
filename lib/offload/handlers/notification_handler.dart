import 'package:vault/offload/handlers/offload_handler.dart';
import 'package:vault/offload/offload_protocol.dart';

/// Optional UI hook for desktop notifications (e.g. SnackBar).
typedef OffloadNotificationCallback = void Function(String title, String body);

/// `vault-notification` — best-effort Windows desktop notify.
///
/// True Windows toast needs a plugin; until then we invoke [onNotify] if set
/// and always return ok with a confirmation message for smoke.
class NotificationHandler implements OffloadHandler {
  NotificationHandler({this.onNotify});

  /// Host UI callback (SnackBar / toast). Optional.
  OffloadNotificationCallback? onNotify;

  @override
  String get permissionId => 'notification';

  @override
  String get command => 'vault-notification';

  @override
  Future<OffloadResponse> handle(OffloadRequest request) async {
    final args = request.args;
    final sub = args.isEmpty ? 'show' : args.first;

    if (sub == 'smoke') {
      _emit('Vault', 'vault-notification smoke');
      return OffloadResponse.ok('ok notification');
    }

    if (sub == 'show' || sub == 'send') {
      final rest = sub == 'show' || sub == 'send'
          ? (args.length > 1 ? args.sublist(1) : const <String>[])
          : args;
      final title = rest.isNotEmpty ? rest.first : 'Vault';
      final body = rest.length > 1 ? rest.sublist(1).join(' ') : '';
      _emit(title, body);
      return OffloadResponse.ok('ok');
    }

    // `vault-notification Title body words...`
    if (args.isNotEmpty) {
      final title = args.first;
      final body = args.length > 1 ? args.sublist(1).join(' ') : '';
      _emit(title, body);
      return OffloadResponse.ok('ok');
    }

    return OffloadResponse.error(
      2,
      'usage: vault-notification show <title> [body]|smoke',
    );
  }

  void _emit(String title, String body) {
    final cb = onNotify;
    if (cb != null) {
      cb(title, body);
      return;
    }
    // Best-effort: no toast plugin — still succeed so smoke/Agent can proceed.
    // ignore: avoid_print
    print('[vault-notification] $title: $body');
  }
}
