import 'package:vault/sandbox/sandbox_models.dart';

/// Guest-git snapshot / restore for a project working tree.
///
/// Uses orphan refs `refs/vault/c/<conversationId>` and `git write-tree` so
/// the user's current branch / HEAD is left alone.
class ProjectCheckpointStore {
  ProjectCheckpointStore({required this.runGuest, required this.projectPath});

  final Future<CommandResult> Function(String cmd) runGuest;
  final String projectPath;

  String get _dir => guestProjectDir(projectPath);

  Future<String?> snapshot(String conversationId) async {
    final id = conversationId.trim();
    if (id.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      return null;
    }
    final dir = shellSingleQuote(_dir);
    final ref = shellSingleQuote('refs/vault/c/$id');
    final script =
        '''
set +e
DIR=$dir
if [ ! -d "\$DIR/.git" ] && [ ! -f "\$DIR/.git" ]; then
  echo ''
  exit 0
fi
cd "\$DIR" || exit 1
git add -A >/dev/null 2>&1
TREE=\$(git write-tree 2>/dev/null) || exit 1
PARENT=\$(git rev-parse $ref 2>/dev/null)
if [ -n "\$PARENT" ]; then
  COMMIT=\$(git commit-tree "\$TREE" -p "\$PARENT" -m "vault checkpoint" 2>/dev/null)
else
  COMMIT=\$(git commit-tree "\$TREE" -m "vault checkpoint" 2>/dev/null)
fi
if [ -n "\$COMMIT" ]; then
  git update-ref $ref "\$COMMIT" >/dev/null 2>&1
fi
printf '%s' "\$TREE"
''';
    try {
      final result = await runGuest(script);
      if (result.exitCode != 0) return null;
      final sha = result.stdout.trim();
      if (sha.isEmpty || !RegExp(r'^[0-9a-f]{40,64}$').hasMatch(sha)) {
        return null;
      }
      return sha;
    } catch (_) {
      return null;
    }
  }

  Future<bool> restore(String treeSha) async {
    final sha = treeSha.trim();
    if (!RegExp(r'^[0-9a-f]{40,64}$').hasMatch(sha)) return false;
    final dir = shellSingleQuote(_dir);
    final quoted = shellSingleQuote(sha);
    final script =
        '''
set -e
DIR=$dir
if [ ! -d "\$DIR/.git" ] && [ ! -f "\$DIR/.git" ]; then
  exit 1
fi
cd "\$DIR"
git read-tree $quoted
git checkout-index -a -f
git clean -fd >/dev/null
''';
    try {
      final result = await runGuest(script);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
