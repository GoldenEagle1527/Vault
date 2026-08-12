import 'package:vault/sandbox/sandbox_models.dart';

/// Guest directory for detached agent shell jobs (parallel with PersistentShell).
const String kGuestShellJobsDir = '/tmp/vault-shell-jobs';

const String kShellJobDoneMarker = '__VAULT_JOB_DONE__';
const String kShellJobOutMarker = '__VAULT_JOB_OUT__';
const String kShellJobEndMarker = '__VAULT_JOB_END__';
const String kShellJobRunningMarker = '__VAULT_JOB_RUNNING__';

/// How often the agent shell tool polls a detached guest job.
const Duration kShellJobPollInterval = Duration(milliseconds: 400);

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

/// Poll script: prints DONE markers + exit/out, or RUNNING + pid.
String buildPollDetachedShellJobCommand(String jobId) {
  final base = guestShellJobBase(jobId);
  final out = shellSingleQuote('$base.out');
  final exitF = shellSingleQuote('$base.exit');
  final pidF = shellSingleQuote('$base.pid');
  return '''
if [ -f $exitF ]; then
  printf '%s\\n' '$kShellJobDoneMarker'
  cat $exitF
  printf '\\n%s\\n' '$kShellJobOutMarker'
  cat $out 2>/dev/null || true
  printf '\\n%s\\n' '$kShellJobEndMarker'
else
  printf '%s\\n' '$kShellJobRunningMarker'
  if [ -f $pidF ]; then cat $pidF; fi
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
  const ShellJobPollResult.running({this.pid})
    : done = false,
      exitCode = null,
      output = null;

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
    var output = '';
    if (parts.length > 1) {
      output = parts.sublist(1).join(kShellJobOutMarker);
      final endIdx = output.indexOf(kShellJobEndMarker);
      if (endIdx >= 0) {
        output = output.substring(0, endIdx);
      }
      if (output.startsWith('\n')) output = output.substring(1);
      if (output.endsWith('\n')) {
        output = output.substring(0, output.length - 1);
      }
    }
    return ShellJobPollResult.done(exitCode: exitCode, output: output);
  }
  if (text.contains(kShellJobRunningMarker)) {
    final after = text.split(kShellJobRunningMarker).last.trim();
    final pidLines = after
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty);
    final pid = pidLines.isEmpty ? null : pidLines.first;
    return ShellJobPollResult.running(pid: pid);
  }
  // Unknown — treat as still running so we keep polling.
  return const ShellJobPollResult.running();
}

String newShellJobId() {
  final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  return 'j$now';
}
