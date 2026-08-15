import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:xterm/xterm.dart';

/// Wires a [SandboxWorkspace] to an [xterm] [TerminalView].
class WorkspaceTerminal extends StatefulWidget {
  const WorkspaceTerminal({
    super.key,
    required this.workspace,
    this.disposeWorkspace = true,
    this.initialGuestCwd,
  });

  final SandboxWorkspace workspace;

  /// When false, only the terminal view is torn down (workspace stays alive).
  final bool disposeWorkspace;

  /// Guest path to `cd` into after the PTY is attached.
  final String? initialGuestCwd;

  @override
  State<WorkspaceTerminal> createState() => _WorkspaceTerminalState();
}

class _WorkspaceTerminalState extends State<WorkspaceTerminal> {
  late final Terminal _terminal;
  StreamSubscription<List<int>>? _outSub;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminal.onOutput = (data) {
      widget.workspace.write(data);
    };
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      widget.workspace.resize(width, height);
    };
    _outSub = widget.workspace.output.listen((chunk) {
      _terminal.write(utf8.decode(chunk, allowMalformed: true));
    });
    final cwd = widget.initialGuestCwd?.trim();
    if (cwd != null && cwd.isNotEmpty) {
      widget.workspace.write('cd ${shellSingleQuote(cwd)}\n');
    }
  }

  @override
  void dispose() {
    _outSub?.cancel();
    if (widget.disposeWorkspace) {
      unawaited(widget.workspace.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hardwareOnly =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    return TerminalView(
      _terminal,
      autofocus: true,
      hardwareKeyboardOnly: hardwareOnly,
      padding: const EdgeInsets.all(4),
      theme: TerminalThemes.defaultTheme,
    );
  }
}
