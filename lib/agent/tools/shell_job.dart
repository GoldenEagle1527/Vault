import 'package:vault/sandbox/sandbox_models.dart';

/// Guest directory for detached agent shell jobs (parallel with PersistentShell).
const String kGuestShellJobsDir = '/tmp/vault-shell-jobs';

const String kShellJobDoneMarker = '__VAULT_JOB_DONE__';
const String kShellJobOutMarker = '__VAULT_JOB_OUT__';
const String kShellJobEndMarker = '__VAULT_JOB_END__';
const String kShellJobRunningMarker = '__VAULT_JOB_RUNNING__';

/// How often the agent shell tool polls a detached guest job.
const Duration kShellJobPollInterval = Duration(milliseconds: 400);

/// Max chars of job output returned in a poll (tail). Keeps marker frames small.
const int kShellJobPollOutputTailChars = 120000;

String guestShellJobBase(String jobId) => '$kGuestShellJobsDir/$jobId';

/// Start [command] as a guest background job so PersistentShell is freed immediately.
///
/// Stdout of the framed [SandboxWorkspace.run] is the job pid (last line).
String buildStartDetachedShellJobCommand({
  required String jobId,
  required String command,
  Map<String, String>? environment,
}) {
  final base = guestShellJobBase(jobId);
  final out = shellSingleQuote('$base.out');
  final exitF = shellSingleQuote('$base.exit');
  final pidF = shellSingleQuote('$base.pid');
  final guestCmd = withGuestEnvironment(command, environment);
  return '''
mkdir -p ${shellSingleQuote(kGuestShellJobsDir)}
rm -f $out $exitF $pidF
( $guestCmd; printf '%s' "\$?" > $exitF ) >$out 2>&1 &
_pid=\$!
printf '%s\\n' "\$_pid" > $pidF
printf '%s\\n' "\$_pid"
'''.trim();
}

/// Poll script: prints DONE or RUNNING, always with current output body.
String buildPollDetachedShellJobCommand(String jobId) {
  final base = guestShellJobBase(jobId);
  final out = shellSingleQuote('$base.out');
  final exitF = shellSingleQuote('$base.exit');
  final pidF = shellSingleQuote('$base.pid');
  // Prefer tail of large logs so notify_regex can still see recent lines.
  final tail = kShellJobPollOutputTailChars;
  return '''
_out() {
  if [ -f $out ]; then
    # BusyBox/coreutils: try tail bytes; fall back to full cat.
    tail -c $tail $out 2>/dev/null || cat $out 2>/dev/null || true
  fi
}
if [ -f $exitF ]; then
  printf '%s\\n' '$kShellJobDoneMarker'
  cat $exitF
  printf '\\n%s\\n' '$kShellJobOutMarker'
  _out
  printf '\\n%s\\n' '$kShellJobEndMarker'
else
  printf '%s\\n' '$kShellJobRunningMarker'
  if [ -f $pidF ]; then cat $pidF; else printf '\\n'; fi
  printf '\\n%s\\n' '$kShellJobOutMarker'
  _out
  printf '\\n%s\\n' '$kShellJobEndMarker'
fi
'''.trim();
}

/// Best-effort kill of a detached job (used on wall-clock timeout).
String buildKillDetachedShellJobCommand(String jobId) {
  final base = guestShellJobBase(jobId);
  final pidF = shellSingleQuote('$base.pid');
  return '''
if [ -f $pidF ]; then
  _pid=\$(cat $pidF 2>/dev/null || true)
  if [ -n "\$_pid" ]; then
    kill "\$_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "\$_pid" 2>/dev/null || true
  fi
fi
'''.trim();
}

class ShellJobPollResult {
  const ShellJobPollResult.running({this.pid, this.output})
    : done = false,
      exitCode = null;

  const ShellJobPollResult.done({
    required int this.exitCode,
    required String this.output,
  }) : done = true,
       pid = null;

  final bool done;
  final int? exitCode;
  final String? output;
  final String? pid;
}

String? _extractMarkedOutput(String afterStatus) {
  final parts = afterStatus.split(kShellJobOutMarker);
  if (parts.length < 2) return null;
  var output = parts.sublist(1).join(kShellJobOutMarker);
  final endIdx = output.indexOf(kShellJobEndMarker);
  if (endIdx >= 0) {
    output = output.substring(0, endIdx);
  }
  if (output.startsWith('\n')) output = output.substring(1);
  if (output.endsWith('\n')) {
    output = output.substring(0, output.length - 1);
  }
  return output;
}

/// Parse stdout from [buildPollDetachedShellJobCommand].
ShellJobPollResult parseShellJobPollStdout(String stdout) {
  final text = stdout.replaceAll('\r\n', '\n');
  if (text.contains(kShellJobDoneMarker)) {
    final afterDone = text.split(kShellJobDoneMarker).last;
    final parts = afterDone.split(kShellJobOutMarker);
    final exitPart = parts.first.trim();
    final exitLine = exitPart
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    final exitCode = int.tryParse(exitLine) ?? -1;
    final output = _extractMarkedOutput(afterDone) ?? '';
    return ShellJobPollResult.done(exitCode: exitCode, output: output);
  }
  if (text.contains(kShellJobRunningMarker)) {
    final after = text.split(kShellJobRunningMarker).last;
    final beforeOut = after.split(kShellJobOutMarker).first.trim();
    final pidLines = beforeOut
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty);
    final pid = pidLines.isEmpty ? null : pidLines.first;
    final output = _extractMarkedOutput(after);
    return ShellJobPollResult.running(pid: pid, output: output);
  }
  // Unknown — treat as still running so we keep polling.
  return const ShellJobPollResult.running();
}

/// Find [pattern] in [output] only for matches ending after [alreadyScanned].
///
/// Returns the matched substring and the new scan cursor, or null if no match.
({String match, int scannedThrough})? findNotifyMatch({
  required String output,
  required RegExp pattern,
  required int alreadyScanned,
}) {
  if (alreadyScanned < 0) alreadyScanned = 0;
  if (alreadyScanned > output.length) alreadyScanned = output.length;
  // Keep a small overlap so patterns spanning the previous boundary still match,
  // but skip hits that end at/before the previous cursor.
  var searchFrom = alreadyScanned > 256 ? alreadyScanned - 256 : 0;
  while (searchFrom <= output.length) {
    final window = output.substring(searchFrom);
    final m = pattern.firstMatch(window);
    if (m == null) return null;
    final absoluteStart = searchFrom + m.start;
    final absoluteEnd = searchFrom + m.end;
    if (absoluteEnd <= alreadyScanned) {
      searchFrom = absoluteStart + 1;
      continue;
    }
    final excerptStart = absoluteStart > 200 ? absoluteStart - 200 : 0;
    final excerptEnd =
        absoluteEnd + 400 < output.length ? absoluteEnd + 400 : output.length;
    var excerpt = output.substring(excerptStart, excerptEnd);
    if (excerptStart > 0) excerpt = '…$excerpt';
    if (excerptEnd < output.length) excerpt = '$excerpt…';
    return (match: excerpt, scannedThrough: absoluteEnd);
  }
  return null;
}

String newShellJobId() {
  final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  return 'j$now';
}
