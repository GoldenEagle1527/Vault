import 'dart:io';

/// Host used to verify outbound connectivity before workspace init.
///
/// Matches the default Alpine apk mirror so the check is relevant to package
/// install (git / python3 / py3-pip).
const String kWorkspaceInitReachabilityHost = 'mirrors.tuna.tsinghua.edu.cn';

/// Returns true when the device can resolve and reach [host] on [port].
///
/// Used to refuse workspace creation when apk/pip downloads would fail.
Future<bool> hasOutboundNetwork({
  String host = kWorkspaceInitReachabilityHost,
  int port = 443,
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    final addresses = await InternetAddress.lookup(host).timeout(timeout);
    if (addresses.isEmpty) return false;

    Socket? socket;
    try {
      socket = await Socket.connect(
        addresses.first,
        port,
        timeout: timeout,
      ).timeout(timeout);
      return true;
    } finally {
      await socket?.close();
    }
  } on Object {
    return false;
  }
}
