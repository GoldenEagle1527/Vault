/// Error returned when the agent tries to start a registered site via `shell`.
const String kSiteStartBypassError = '不要用 shell 起网站。请用 manage_site action=start。';

final _quotedDashC = RegExp(
  r'''python3?\s+-c\s+(['"]).+?\1''',
  dotAll: true,
);
final _unquotedDashC = RegExp(r'python3?\s+-c\s+\S+');
final _runAppPy = RegExp(
  r'(?:^|[\s;&|]|nohup\s+)(?:python3?)\s+app\.py\b',
);
final _runHttpServer = RegExp(
  r'(?:^|[\s;&|]|nohup\s+)(?:python3?)\s+-m\s+http\.server\b',
);
final _runFlask = RegExp(r'(?:^|[\s;&|]|nohup\s+)flask\s+run\b');

/// Whether [command] is trying to start an HTTP site instead of using manage_site.
bool looksLikeSiteStartCommand(
  String command, {
  String? registeredStartCommand,
}) {
  var text = command.trim();
  if (text.isEmpty) return false;
  text = text.replaceAll(_quotedDashC, ' ').replaceAll(_unquotedDashC, ' ');
  text = text.replaceAll(RegExp(r'\s+'), ' ');

  final registered = registeredStartCommand?.trim();
  if (registered != null &&
      registered.isNotEmpty &&
      text.contains(registered)) {
    return true;
  }
  return _runAppPy.hasMatch(text) ||
      _runHttpServer.hasMatch(text) ||
      _runFlask.hasMatch(text);
}

String? siteStartBypassError(
  String command, {
  String? registeredStartCommand,
}) {
  if (!looksLikeSiteStartCommand(
    command,
    registeredStartCommand: registeredStartCommand,
  )) {
    return null;
  }
  return kSiteStartBypassError;
}
