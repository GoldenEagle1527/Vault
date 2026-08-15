import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/agent/project_checkpoint.dart';
import 'package:vault/sandbox/sandbox_models.dart';

void main() {
  late Directory temp;
  late String projectPath;
  late String hostDir;
  late ProjectCheckpointStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vault_ckpt_');
    projectPath = '20260101120000';
    hostDir = p.join(temp.path, 'root', 'projects', projectPath);
    await Directory(hostDir).create(recursive: true);
    store = ProjectCheckpointStore(
      projectPath: projectPath,
      runGuest: (cmd) => _runGitScript(cmd, hostDir: hostDir),
    );
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<void> initGit() async {
    final git = await Process.run('git', ['--version']);
    if (git.exitCode != 0) {
      fail('git is required for project checkpoint tests');
    }
    await Process.run('git', ['init'], workingDirectory: hostDir);
    await Process.run(
      'git',
      ['config', 'user.name', 'Vault'],
      workingDirectory: hostDir,
    );
    await Process.run(
      'git',
      ['config', 'user.email', 'vault@local'],
      workingDirectory: hostDir,
    );
  }

  test('snapshot then restore rewinds project files', () async {
    await initGit();
    await File(p.join(hostDir, 'a.txt')).writeAsString('v1');
    final sha1 = await store.snapshot('conv1');
    expect(sha1, isNotNull);
    expect(sha1, matches(RegExp(r'^[0-9a-f]{40,64}$')));

    await File(p.join(hostDir, 'a.txt')).writeAsString('v2');
    await File(p.join(hostDir, 'b.txt')).writeAsString('extra');
    final sha2 = await store.snapshot('conv1');
    expect(sha2, isNotNull);
    expect(sha2, isNot(sha1));

    final ok = await store.restore(sha1!);
    expect(ok, isTrue);
    expect(await File(p.join(hostDir, 'a.txt')).readAsString(), 'v1');
    expect(await File(p.join(hostDir, 'b.txt')).exists(), isFalse);
  });

  test('snapshot rejects invalid conversation ids', () async {
    expect(await store.snapshot('bad id!'), isNull);
    expect(await store.snapshot(''), isNull);
  });

  test('restore rejects invalid sha', () async {
    expect(await store.restore('not-a-sha'), isFalse);
  });
}

/// Host-side stand-in for guest bash: same git steps as [ProjectCheckpointStore].
Future<CommandResult> _runGitScript(
  String cmd, {
  required String hostDir,
}) async {
  Future<ProcessResult> git(List<String> args) {
    return Process.run(
      'git',
      args,
      workingDirectory: hostDir,
      environment: {
        ...Platform.environment,
        'GIT_AUTHOR_NAME': 'Vault',
        'GIT_AUTHOR_EMAIL': 'vault@local',
        'GIT_COMMITTER_NAME': 'Vault',
        'GIT_COMMITTER_EMAIL': 'vault@local',
      },
    );
  }

  if (cmd.contains('git write-tree')) {
    if (!await Directory(p.join(hostDir, '.git')).exists() &&
        !await File(p.join(hostDir, '.git')).exists()) {
      return const CommandResult(exitCode: 0, stdout: '', stderr: '');
    }
    await git(['add', '-A']);
    final tree = await git(['write-tree']);
    if (tree.exitCode != 0) {
      return CommandResult(
        exitCode: tree.exitCode,
        stdout: '',
        stderr: tree.stderr.toString(),
      );
    }
    final treeSha = tree.stdout.toString().trim();
    final refMatch = RegExp(r'refs/vault/c/([A-Za-z0-9_-]+)').firstMatch(cmd);
    if (refMatch != null) {
      final ref = 'refs/vault/c/${refMatch.group(1)}';
      final parent = await git(['rev-parse', ref]);
      final parentSha =
          parent.exitCode == 0 ? parent.stdout.toString().trim() : '';
      final commit = await git([
        'commit-tree',
        treeSha,
        if (parentSha.isNotEmpty) ...['-p', parentSha],
        '-m',
        'vault checkpoint',
      ]);
      final commitSha = commit.stdout.toString().trim();
      if (commit.exitCode == 0 && commitSha.isNotEmpty) {
        await git(['update-ref', ref, commitSha]);
      }
    }
    return CommandResult(exitCode: 0, stdout: treeSha, stderr: '');
  }

  if (cmd.contains('git read-tree')) {
    final shaMatch = RegExp(
      r"git read-tree '([0-9a-f]{40,64})'",
    ).firstMatch(cmd);
    if (shaMatch == null) {
      return const CommandResult(exitCode: 1, stdout: '', stderr: 'no sha');
    }
    final sha = shaMatch.group(1)!;
    final read = await git(['read-tree', sha]);
    if (read.exitCode != 0) {
      return CommandResult(
        exitCode: read.exitCode,
        stdout: '',
        stderr: read.stderr.toString(),
      );
    }
    await git(['checkout-index', '-a', '-f']);
    await git(['clean', '-fd']);
    return const CommandResult(exitCode: 0, stdout: '', stderr: '');
  }

  return const CommandResult(exitCode: 1, stdout: '', stderr: 'unhandled');
}
