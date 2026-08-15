import 'package:flutter/material.dart';
import 'package:vault/agent/workspace_store.dart';

/// Shows a dialog to name a new workspace.
///
/// Default name is [kDefaultWorkspaceName] / `新工作区(n)` when taken.
/// Focus selects all text so the user can overwrite quickly.
Future<String?> showNewWorkspaceDialog(
  BuildContext context, {
  required Iterable<String> existingNames,
}) {
  final initial = WorkspaceStore.allocateDisplayName(existingNames);
  return showDialog<String>(
    context: context,
    builder: (ctx) => _NewWorkspaceDialog(initialName: initial),
  );
}

class _NewWorkspaceDialog extends StatefulWidget {
  const _NewWorkspaceDialog({required this.initialName});

  final String initialName;

  @override
  State<_NewWorkspaceDialog> createState() => _NewWorkspaceDialogState();
}

class _NewWorkspaceDialogState extends State<_NewWorkspaceDialog> {
  late final TextEditingController _nameCtrl;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _selectAll();
    });
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      _selectAll();
    }
  }

  void _selectAll() {
    _nameCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _nameCtrl.text.length,
    );
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建工作区'),
      content: TextField(
        controller: _nameCtrl,
        focusNode: _focusNode,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '工作区名称',
          border: OutlineInputBorder(),
        ),
        textInputAction: TextInputAction.done,
        onTap: _selectAll,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('创建')),
      ],
    );
  }
}
