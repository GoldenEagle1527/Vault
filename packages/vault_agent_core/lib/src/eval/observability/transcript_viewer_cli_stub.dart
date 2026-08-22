/// Native transcript CLI compatibility entry point.
///
/// The CLI requires `dart:io`; import and use the pure `TranscriptViewer`
/// formatter on platforms without it.
Future<int> runTranscriptViewer(
  List<String> args, {
  StringSink? stdoutSink,
  StringSink? stderrSink,
}) {
  throw UnsupportedError('The transcript viewer CLI requires dart:io.');
}
