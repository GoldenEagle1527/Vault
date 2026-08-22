import 'package:vault/sandbox/sandbox_provider.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/sandbox/workspace_bootstrap.dart';
import 'package:vault/sandbox/workspace_guest_fs.dart';

/// Guest filesystem and git operations used by the project facade.
class ProjectGuestOperations {
  ProjectGuestOperations({
    required WorkspaceGuestFs fs,
    required Future<CommandResult> Function(String workspaceId, String command)
    runGuest,
  }) : this._(fs, runGuest);

  ProjectGuestOperations._(this._fs, this._runGuest);

  final WorkspaceGuestFs _fs;
  final Future<CommandResult> Function(String workspaceId, String command)
  _runGuest;

  Future<CommandResult> bootstrap(String workspaceId) {
    return _runGuest(workspaceId, workspaceGitAndDirsBootstrapScript());
  }

  Future<void> createProjectDirectory(
    String workspaceId,
    String projectPath,
  ) async {
    final result = await _initializeProjectDirectory(workspaceId, projectPath);
    if (result.exitCode != 0) {
      throw StateError(
        '创建项目目录 / git init 失败（${result.exitCode}）：'
        '${result.stderr}\n${result.stdout}',
      );
    }
  }

  /// Legacy migration historically treated guest initialization as best effort.
  Future<void> createLegacyProjectDirectory(
    String workspaceId,
    String projectPath,
  ) async {
    await _initializeProjectDirectory(workspaceId, projectPath);
  }

  Future<CommandResult> _initializeProjectDirectory(
    String workspaceId,
    String projectPath,
  ) {
    final guestDir = guestProjectDir(projectPath);
    return _runGuest(
      workspaceId,
      'mkdir -p ${shellSingleQuote(guestDir)}/$kProjectInboxDirName && '
      'git -C ${shellSingleQuote(guestDir)} init && '
      'printf "inbox/\\n" >> ${shellSingleQuote(guestDir)}/.gitignore',
    );
  }

  Future<void> deleteProjectDirectory(
    String workspaceId,
    String projectPath,
  ) async {
    try {
      await _fs.deletePath(
        workspaceId,
        guestProjectDir(projectPath),
        recursive: true,
      );
    } catch (_) {}
  }

  Future<String?> readLegacyIndex(String workspaceId) =>
      _fs.readUtf8(workspaceId, '$kGuestLegacyConversationsDir/index.json');

  Future<String?> readLegacyConversation(
    String workspaceId,
    String conversationId,
  ) => _fs.readUtf8(
    workspaceId,
    '$kGuestLegacyConversationsDir/$conversationId.json',
  );

  Future<void> deleteLegacyConversations(String workspaceId) async {
    try {
      await _fs.deletePath(
        workspaceId,
        kGuestLegacyConversationsDir,
        recursive: true,
      );
    } catch (_) {}
  }
}
