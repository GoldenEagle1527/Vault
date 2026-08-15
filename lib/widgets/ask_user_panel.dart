import 'package:flutter/material.dart';
import 'package:vault/agent/ask_user.dart';
import 'package:vault/widgets/glass.dart';

/// Paged questionnaire: question on top, choices below, plus a write-in.
class AskUserPanel extends StatefulWidget {
  const AskUserPanel({
    super.key,
    required this.questionnaire,
    required this.onSubmit,
  });

  final AskUserQuestionnaire questionnaire;
  final ValueChanged<List<AskUserAnswer>> onSubmit;

  @override
  State<AskUserPanel> createState() => _AskUserPanelState();
}

class _AskUserDraft {
  _AskUserDraft();

  final Set<String> selectedIds = {};
  bool writeIn = false;
  String customText = '';

  bool get hasAnswer =>
      selectedIds.isNotEmpty || (writeIn && customText.trim().isNotEmpty);

  AskUserAnswer toAnswer(String questionId) {
    return AskUserAnswer(
      id: questionId,
      selectedIds: selectedIds.toList(),
      customText: writeIn ? customText.trim() : null,
    );
  }
}

class _AskUserPanelState extends State<AskUserPanel> {
  late final PageController _pageCtrl;
  late final List<_AskUserDraft> _drafts;
  late final List<TextEditingController> _customCtrls;
  var _page = 0;

  List<AskUserQuestion> get _questions => widget.questionnaire.questions;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController();
    _drafts = [for (final _ in _questions) _AskUserDraft()];
    _customCtrls = [for (final _ in _questions) TextEditingController()];
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    for (final c in _customCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _allAnswered => _drafts.every((d) => d.hasAnswer);

  void _goTo(int index) {
    final clamped = index.clamp(0, _questions.length - 1);
    _pageCtrl.animateToPage(
      clamped,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _toggleSingle(_AskUserDraft draft, String id) {
    setState(() {
      draft.writeIn = false;
      draft.selectedIds
        ..clear()
        ..add(id);
    });
  }

  void _toggleMulti(_AskUserDraft draft, String id) {
    setState(() {
      if (draft.selectedIds.contains(id)) {
        draft.selectedIds.remove(id);
      } else {
        draft.selectedIds.add(id);
      }
    });
  }

  void _toggleWriteIn(_AskUserDraft draft, {required bool single}) {
    setState(() {
      draft.writeIn = !draft.writeIn;
      if (single && draft.writeIn) draft.selectedIds.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final last = _page >= _questions.length - 1;
    return GlassPanel(
      borderRadius: 24,
      tone: GlassTone.strong,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '请选一下',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const Spacer(),
              Text(
                '${_page + 1} / ${_questions.length}',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: (MediaQuery.sizeOf(context).height * 0.32).clamp(180.0, 280.0),
            child: PageView.builder(
              controller: _pageCtrl,
              itemCount: _questions.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (context, i) => _QuestionPage(
                question: _questions[i],
                draft: _drafts[i],
                customCtrl: _customCtrls[i],
                onSelect: (id) {
                  final q = _questions[i];
                  if (q.allowMultiple) {
                    _toggleMulti(_drafts[i], id);
                  } else {
                    _toggleSingle(_drafts[i], id);
                  }
                },
                onToggleWriteIn: () => _toggleWriteIn(
                  _drafts[i],
                  single: !_questions[i].allowMultiple,
                ),
                onCustomChanged: (text) {
                  setState(() => _drafts[i].customText = text);
                },
              ),
            ),
          ),
          if (_questions.length > 1) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _questions.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _page
                            ? scheme.primary
                            : scheme.outlineVariant,
                      ),
                      child: const SizedBox(width: 7, height: 7),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              TextButton(
                onPressed: _page == 0 ? null : () => _goTo(_page - 1),
                child: const Text('上一题'),
              ),
              const Spacer(),
              if (!last)
                FilledButton.tonal(
                  onPressed: () => _goTo(_page + 1),
                  child: const Text('下一题'),
                )
              else
                FilledButton(
                  onPressed: _allAnswered
                      ? () => widget.onSubmit([
                            for (var i = 0; i < _questions.length; i++)
                              _drafts[i].toAnswer(_questions[i].id),
                          ])
                      : null,
                  child: const Text('选好了'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuestionPage extends StatelessWidget {
  const _QuestionPage({
    required this.question,
    required this.draft,
    required this.customCtrl,
    required this.onSelect,
    required this.onToggleWriteIn,
    required this.onCustomChanged,
  });

  final AskUserQuestion question;
  final _AskUserDraft draft;
  final TextEditingController customCtrl;
  final ValueChanged<String> onSelect;
  final VoidCallback onToggleWriteIn;
  final ValueChanged<String> onCustomChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(right: 4),
      children: [
        Text(
          question.prompt,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        if (question.allowMultiple)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '可以多选',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
        const SizedBox(height: 12),
        for (final opt in question.options) ...[
          _ChoiceTile(
            selected: draft.selectedIds.contains(opt.id),
            multiple: question.allowMultiple,
            label: opt.label,
            onTap: () => onSelect(opt.id),
          ),
          const SizedBox(height: 8),
        ],
        _ChoiceTile(
          selected: draft.writeIn,
          multiple: question.allowMultiple,
          label: '自己填写',
          onTap: onToggleWriteIn,
        ),
        if (draft.writeIn) ...[
          const SizedBox(height: 8),
          TextField(
            controller: customCtrl,
            autofocus: true,
            minLines: 1,
            maxLines: 3,
            onChanged: onCustomChanged,
            decoration: const InputDecoration(
              hintText: '用你自己的话说…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.selected,
    required this.multiple,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final bool multiple;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primaryContainer.withValues(alpha: 0.85)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                multiple
                    ? (selected
                        ? Icons.check_box
                        : Icons.check_box_outline_blank)
                    : (selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off),
                size: 22,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
