import 'dart:io';

import 'package:vault_agent_core/src/eval/observability/transcript_viewer_cli.dart';

Future<void> main(List<String> args) async {
  final code = await runTranscriptViewer(args);
  if (code != 0) exit(code);
}
