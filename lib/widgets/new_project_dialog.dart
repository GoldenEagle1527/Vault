import 'package:flutter/material.dart';
import 'package:vault/agent/project_store.dart';

/// Shows a dialog to name a new project.
///
/// Default name is [kDefaultProjectName] / `新项目(n)` when taken.
/// Focus selects all text so the user can overwrite quickly.
Future<String?> showNewProjectDialog(
  BuildContext context, {
  required Iterable<String> existingNames,
}) {
  final initial = ProjectStore.allocateDisplayName(existingNames);
  return showDialog<String>(
    context: context,
    builder: (ctx) => _NewProjectDialog(initialName: initial),
  );
}

class _NewProjectDialog extends StatefulWidget {
  const _NewProjectDialog({required this.initialName});

  final String initialName;

  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
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
      title: const Text('新建项目'),
      content: TextField(
        controller: _nameCtrl,
        focusNode: _focusNode,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '项目名称',
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
        FilledButton(
          onPressed: _submit,
          child: const Text('创建'),
        ),
      ],
    );
  }
}
