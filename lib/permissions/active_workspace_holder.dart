import 'package:vault/sandbox/sandbox_models.dart';

/// App-wide hook so Settings / diagnostics can reach an open [SandboxWorkspace].
///
/// Wiring:
/// - [AgentScreen] sets [current] while a workspace chat is open.
/// - [HomeScreen] may set [resolver] to temporarily [SandboxProvider.attach]
///   the first listed workspace for smoke tests.
///
/// Prefer [resolve] from Settings; if both are null, show
/// 「请先创建并打开一个工作区」.
class ActiveWorkspaceHolder {
  ActiveWorkspaceHolder._();

  /// Workspace currently shown in [AgentScreen], if any.
  static SandboxWorkspace? current;

  /// Optional lazy attach (set by home). Must not dispose [current].
  static Future<SandboxWorkspace?> Function()? resolver;

  static Future<SandboxWorkspace?> resolve() async {
    final open = current;
    if (open != null) return open;
    final r = resolver;
    if (r != null) return r();
    return null;
  }
}
