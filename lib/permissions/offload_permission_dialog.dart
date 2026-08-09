import 'package:flutter/material.dart';
import 'package:vault/permissions/offload_permission_manager.dart';
import 'package:vault/permissions/permission_models.dart';

/// Listens to [OffloadPermissionManager.pendingRequest] and shows an ASK dialog.
///
/// Place once near the app root (e.g. [HomeScreen]) so prompts work from any
/// route while a vault-* call is gated.
class OffloadPermissionDialogHost extends StatefulWidget {
  const OffloadPermissionDialogHost({
    super.key,
    required this.child,
    this.manager,
  });

  final Widget child;
  final OffloadPermissionManager? manager;

  @override
  State<OffloadPermissionDialogHost> createState() =>
      _OffloadPermissionDialogHostState();
}

class _OffloadPermissionDialogHostState
    extends State<OffloadPermissionDialogHost> {
  late final OffloadPermissionManager _manager;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _manager = widget.manager ?? OffloadPermissionManager.instance;
    _manager.pendingRequest.addListener(_onPendingChanged);
  }

  @override
  void dispose() {
    _manager.pendingRequest.removeListener(_onPendingChanged);
    super.dispose();
  }

  void _onPendingChanged() {
    final pending = _manager.pendingRequest.value;
    if (pending == null || _dialogOpen || !mounted) return;
    _dialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _dialogOpen = false;
        return;
      }
      final choice = await showOffloadPermissionDialog(
        context,
        permissionName: pending.displayNameZh,
        cliName: pending.cliName,
      );
      if (choice != null) {
        _manager.respondToPending(choice);
      } else {
        // Dismiss / back → deny for this session.
        _manager.respondToPending(AskResponse.denySession);
      }
      _dialogOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Modal ASK_ONCE chooser. Returns null if the user dismisses without a choice.
Future<AskResponse?> showOffloadPermissionDialog(
  BuildContext context, {
  required String permissionName,
  required String cliName,
}) {
  return showDialog<AskResponse>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('权限请求'),
        content: Text(
          '应用内能力「$permissionName」想要在当前会话中使用（$cliName）。\n'
          '请选择是否允许。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(AskResponse.denySession),
            child: const Text('本会话拒绝'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(AskResponse.allowOnce),
            child: const Text('仅允许一次'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(AskResponse.allowSession),
            child: const Text('本会话允许'),
          ),
        ],
      );
    },
  );
}
