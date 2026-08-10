import 'package:vault/sandbox/sandbox_provider.dart';

/// Guest shell snippet: ensure project dirs exist and configure global git.
String workspaceGitAndDirsBootstrapScript() => '''
set -e
mkdir -p ${shellSingleQuote(kGuestProjectsDir)} ${shellSingleQuote(kGuestVaultDir)}
git config --global user.name "Vault"
git config --global user.email "vault@local"
git config --global init.defaultBranch main
''';

/// Idempotent workspace Linux bootstrap (dirs + global git). Safe on attach.
Future<void> bootstrapWorkspaceGuest(SandboxProvider provider, String workspaceId) async {
  final result = await provider.runGuestCommand(
    workspaceId,
    workspaceGitAndDirsBootstrapScript(),
  );
  if (result.exitCode != 0) {
    throw StateError(
      '工作区 bootstrap 失败（${result.exitCode}）：'
      '${result.stderr}\n${result.stdout}',
    );
  }
}
