import 'package:flutter/material.dart';
import 'package:vault/agent/ask_user.dart';
import 'package:vault/widgets/glass.dart';

/// Completed `ask_user` turn: questions and answers, optional reselect.
class AskUserTranscript extends StatelessWidget {
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

  AskUserQuestionnaire? get _questionnaire =>
      AskUserQuestionnaire.tryParseArguments(arguments);

  List<AskUserAnswer> get _answers {
    final raw = result;
    if (raw == null || raw.isEmpty) return const [];
    return AskUserAnswer.tryParseResult(raw);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final q = _questionnaire;
    final byId = {for (final a in _answers) a.id: a};

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassPanel(
            borderRadius: 10,
            tone: GlassTone.regular,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.attachment,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '回答',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    if (onReselect != null)
                      TextButton(
                        onPressed: onReselect,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: scheme.onSurfaceVariant,
                        ),
                        child: const Text('重选'),
                      ),
                  ],
                ),
                if (q == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      arguments,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  for (var i = 0; i < q.questions.length; i++) ...[
                    if (i > 0)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Divider(
                          height: 1,
                          thickness: 1,
                          color: scheme.outlineVariant.withValues(alpha: 0.45),
                        ),
                      )
                    else
                      const SizedBox(height: 12),
                    _QaBlock(
                      question: q.questions[i],
                      answer: byId[q.questions[i].id],
                    ),
                  ],
              ],
            ),
          ),
          if (branchSwitcher != null) branchSwitcher!,
        ],
      ),
    );
  }
}

class _QaBlock extends StatelessWidget {
  const _QaBlock({required this.question, this.answer});

  final AskUserQuestion question;
  final AskUserAnswer? answer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          question.prompt,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _answerLabel(question, answer),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurface,
            fontWeight: FontWeight.w700,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

String _answerLabel(AskUserQuestion question, AskUserAnswer? answer) {
  if (answer == null) return '（未作答）';
  final labels = <String>[
    for (final id in answer.selectedIds)
      question.options
              .where((o) => o.id == id)
              .map((o) => o.label)
              .firstOrNull ??
          id,
    if (answer.customText != null && answer.customText!.trim().isNotEmpty)
      answer.customText!.trim(),
  ];
  return labels.isEmpty ? '（未作答）' : labels.join('、');
}
