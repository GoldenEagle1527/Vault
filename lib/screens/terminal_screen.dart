import 'package:flutter/material.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/widgets/session_terminal.dart';

class TerminalScreen extends StatelessWidget {
  const TerminalScreen({
    super.key,
    required this.title,
    required this.session,
  });

  final String title;
  final SandboxSession session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SessionTerminal(session: session),
    );
  }
}
