import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:xterm/xterm.dart';

/// Wires a [SandboxSession] to an [xterm] [TerminalView].
class SessionTerminal extends StatefulWidget {
  const SessionTerminal({super.key, required this.session});

  final SandboxSession session;

  @override
  State<SessionTerminal> createState() => _SessionTerminalState();
}

class _SessionTerminalState extends State<SessionTerminal> {
  late final Terminal _terminal;
  StreamSubscription<List<int>>? _outSub;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _terminal.onOutput = (data) {
      widget.session.write(data);
    };
    _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      widget.session.resize(width, height);
    };
    _outSub = widget.session.output.listen((chunk) {
      _terminal.write(utf8.decode(chunk, allowMalformed: true));
    });
  }

  @override
  void dispose() {
    _outSub?.cancel();
    unawaited(widget.session.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hardwareOnly = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    return TerminalView(
      _terminal,
      autofocus: true,
      hardwareKeyboardOnly: hardwareOnly,
      padding: const EdgeInsets.all(4),
      theme: TerminalThemes.defaultTheme,
    );
  }
}
