import 'package:flutter/material.dart';
import 'package:vault/agent/agent_settings.dart';
import 'package:vault/widgets/glass.dart';

class AgentComposer extends StatelessWidget {
  const AgentComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.running,
    required this.onAttach,
    required this.onPaste,
    required this.onSend,
    required this.onCancel,
    required this.profileSwitcher,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool running;
  final VoidCallback onAttach;
  final VoidCallback onPaste;
  final VoidCallback onSend;
  final VoidCallback onCancel;
  final Widget profileSwitcher;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      borderRadius: 28,
      tone: GlassTone.strong,
      padding: const EdgeInsets.all(4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: '添加文件',
            onPressed: running ? null : onAttach,
            icon: const Icon(Icons.attach_file),
          ),
          Expanded(
            child: Actions(
              actions: {
                PasteTextIntent: CallbackAction<PasteTextIntent>(
                  onInvoke: (_) {
                    onPaste();
                    return null;
                  },
                ),
              },
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 5,
                enabled: !running,
                textInputAction: TextInputAction.newline,
                keyboardType: TextInputType.multiline,
                decoration: const InputDecoration(
                  hintText: '继续描述你的需求…',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 12,
                  ),
                ),
              ),
            ),
          ),
          profileSwitcher,
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 2),
            child: IconButton.filled(
              tooltip: running ? '停止' : '发送',
              onPressed: running ? onCancel : onSend,
              icon: Icon(running ? Icons.stop_rounded : Icons.send),
            ),
          ),
        ],
      ),
    );
  }
}

class AgentProfileSwitcher extends StatelessWidget {
  const AgentProfileSwitcher({
    super.key,
    required this.profiles,
    required this.activeProfileId,
    required this.onSelected,
  });

  final List<AgentSettings> profiles;
  final String activeProfileId;
  final ValueChanged<String> onSelected;

  AgentSettings get _current {
    for (final profile in profiles) {
      if (profile.id == activeProfileId) return profile;
    }
    return profiles.isEmpty ? AgentSettings.defaults : profiles.first;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = _current;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: PopupMenuButton<String>(
        tooltip: '切换模型配置',
        initialValue: current.id,
        enabled: profiles.isNotEmpty,
        onSelected: onSelected,
        itemBuilder: (context) => [
          for (final profile in profiles)
            PopupMenuItem(
              value: profile.id,
              child: Text(profile.displayName, overflow: TextOverflow.ellipsis),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 2, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 96),
                child: Text(
                  current.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_drop_down,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
