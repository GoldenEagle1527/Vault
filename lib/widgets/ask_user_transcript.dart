import 'package:flutter/material.dart';
import 'package:vault/agent/ask_user.dart';
import 'package:vault/widgets/glass.dart';

/// Completed `ask_user` turn: questions, answers, raw JSON, reselect.
class AskUserTranscript extends StatefulWidget {
  const AskUserTranscript({
    super.key,
    required this.arguments,
    this.result,
    this.onReselect,
    this.branchSwitcher,
  });

  final String arguments;
  final String? result;
  final VoidCallback? onReselect;
  final Widget? branchSwitcher;

  @override
  State<AskUserTranscript> createState() => _AskUserTranscriptState();
}

class _AskUserTranscriptState extends State<AskUserTranscript> {
  var _showRaw = false;

  AskUserQuestionnaire? get _questionnaire =>
      AskUserQuestionnaire.tryParseArguments(widget.arguments);

  List<AskUserAnswer> get _answers {
    final raw = widget.result;
    if (raw == null || raw.isEmpty) return const [];
    return AskUserAnswer.tryParseResult(raw);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _questionnaire;
    final answers = _answers;
    final byId = {for (final a in answers) a.id: a};

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassPanel(
            borderRadius: 16,
            tone: GlassTone.regular,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.quiz_outlined, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '提问',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (widget.onReselect != null)
                      TextButton(
                        onPressed: widget.onReselect,
                        child: const Text('重选'),
                      ),
                  ],
                ),
                if (q == null)
                  Text(
                    widget.arguments,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  )
                else
                  for (final question in q.questions) ...[
                    const SizedBox(height: 8),
                    Text(
                      question.prompt,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _AnswerLine(question: question, answer: byId[question.id]),
                  ],
                const SizedBox(height: 8),
                InkWell(
                  onTap: () => setState(() => _showRaw = !_showRaw),
                  child: Row(
                    children: [
                      Icon(
                        _showRaw
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      Text(
                        '原始数据',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (_showRaw) ...[
                  SelectableText(
                    widget.arguments,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                  if (widget.result != null && widget.result!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      widget.result!,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          if (widget.branchSwitcher != null) widget.branchSwitcher!,
        ],
      ),
    );
  }
}

class _AnswerLine extends StatelessWidget {
  const _AnswerLine({required this.question, this.answer});

  final AskUserQuestion question;
  final AskUserAnswer? answer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final answer = this.answer;
    if (answer == null) {
      return Text(
        '（未作答）',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    }
    final chips = <String>[
      for (final id in answer.selectedIds)
        question.options
                .where((o) => o.id == id)
                .map((o) => o.label)
                .firstOrNull ??
            id,
      if (answer.customText != null && answer.customText!.trim().isNotEmpty)
        answer.customText!.trim(),
    ];
    if (chips.isEmpty) {
      return Text(
        '（未作答）',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final label in chips)
          Chip(
            label: Text(label),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
      ],
    );
  }
}
