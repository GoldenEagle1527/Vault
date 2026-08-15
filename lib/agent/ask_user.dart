import 'dart:async';

import 'package:flutter/foundation.dart';

const String kAskUserToolName = 'ask_user';

/// One choice the model offered (UI always adds a write-in on top of these).
class AskUserOption {
  const AskUserOption({required this.id, required this.label});

  final String id;
  final String label;
}

class AskUserQuestion {
  const AskUserQuestion({
    required this.id,
    required this.prompt,
    required this.allowMultiple,
    required this.options,
  });

  final String id;
  final String prompt;
  final bool allowMultiple;
  final List<AskUserOption> options;
}

class AskUserQuestionnaire {
  const AskUserQuestionnaire({required this.questions});

  final List<AskUserQuestion> questions;

  static const int maxQuestions = 8;
  static const int maxOptions = 12;

  /// Best-effort parse of the model's tool arguments. Returns null if unusable.
  static AskUserQuestionnaire? tryParse(Map<String, dynamic> args) {
    final raw = args['questions'];
    if (raw is! List || raw.isEmpty) return null;
    final questions = <AskUserQuestion>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final prompt = (map['prompt'] as String?)?.trim() ??
          (map['question'] as String?)?.trim() ??
          '';
      if (prompt.isEmpty) continue;
      final id = (map['id'] as String?)?.trim();
      final allowMultiple = map['allow_multiple'] == true ||
          map['allowMultiple'] == true ||
          map['multi'] == true;
      final options = <AskUserOption>[];
      final rawOpts = map['options'];
      if (rawOpts is List) {
        for (var i = 0; i < rawOpts.length && options.length < maxOptions; i++) {
          final opt = rawOpts[i];
          if (opt is String) {
            final label = opt.trim();
            if (label.isEmpty) continue;
            options.add(AskUserOption(id: 'opt_$i', label: label));
            continue;
          }
          if (opt is! Map) continue;
          final om = opt.cast<String, dynamic>();
          final label = (om['label'] as String?)?.trim() ??
              (om['text'] as String?)?.trim() ??
              '';
          if (label.isEmpty) continue;
          final oid = (om['id'] as String?)?.trim();
          options.add(AskUserOption(id: oid ?? 'opt_$i', label: label));
        }
      }
      questions.add(
        AskUserQuestion(
          id: (id == null || id.isEmpty) ? 'q_${questions.length}' : id,
          prompt: prompt,
          allowMultiple: allowMultiple,
          options: options,
        ),
      );
      if (questions.length >= maxQuestions) break;
    }
    if (questions.isEmpty) return null;
    return AskUserQuestionnaire(questions: questions);
  }
}

class AskUserAnswer {
  const AskUserAnswer({
    required this.id,
    required this.selectedIds,
    this.customText,
  });

  final String id;
  final List<String> selectedIds;
  final String? customText;

  Map<String, dynamic> toJson() => {
        'id': id,
        'selected_ids': selectedIds,
        if (customText != null && customText!.isNotEmpty)
          'custom_text': customText,
      };
}

class AskUserSubmission {
  const AskUserSubmission._({
    required this.cancelled,
    this.cancelReason,
    this.answers = const [],
  });

  const AskUserSubmission.ok(List<AskUserAnswer> answers)
      : this._(cancelled: false, answers: answers);

  const AskUserSubmission.cancelled([String reason = '用户取消'])
      : this._(cancelled: true, cancelReason: reason);

  final bool cancelled;
  final String? cancelReason;
  final List<AskUserAnswer> answers;

  Map<String, dynamic> toToolResult() {
    if (cancelled) {
      return {
        'ok': false,
        'cancelled': true,
        'error': cancelReason ?? '用户取消',
      };
    }
    return {
      'ok': true,
      'answers': [for (final a in answers) a.toJson()],
    };
  }
}

class AskUserSession {
  AskUserSession(this.questionnaire);

  final AskUserQuestionnaire questionnaire;
  final Completer<AskUserSubmission> completer = Completer<AskUserSubmission>();

  void complete(AskUserSubmission submission) {
    if (!completer.isCompleted) completer.complete(submission);
  }
}

/// Host-side gate: the tool awaits [present]; the UI listens to [pending].
class AskUserHost {
  final ValueNotifier<AskUserSession?> pending = ValueNotifier<AskUserSession?>(
    null,
  );

  Future<AskUserSubmission> present(AskUserQuestionnaire questionnaire) async {
    cancelAll(reason: '被新的提问替换');
    final session = AskUserSession(questionnaire);
    pending.value = session;
    try {
      return await session.completer.future;
    } finally {
      if (identical(pending.value, session)) {
        pending.value = null;
      }
    }
  }

  void cancelAll({String reason = '用户取消'}) {
    final session = pending.value;
    if (session == null) return;
    session.complete(AskUserSubmission.cancelled(reason));
    pending.value = null;
  }

  void dispose() {
    cancelAll();
    pending.dispose();
  }
}
