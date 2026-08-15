import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/ask_user.dart';

void main() {
  test('tryParse accepts id/prompt/options maps', () {
    final q = AskUserQuestionnaire.tryParse({
      'questions': [
        {
          'id': 'who',
          'prompt': '给谁用？',
          'allow_multiple': false,
          'options': [
            {'id': 'self', 'label': '自己'},
            {'id': 'others', 'label': '别人'},
          ],
        },
        {
          'id': 'feats',
          'question': '先做哪几件？',
          'allowMultiple': true,
          'options': ['分类', {'id': 'dup', 'text': '去重'}],
        },
      ],
    });
    expect(q, isNotNull);
    expect(q!.questions, hasLength(2));
    expect(q.questions[0].id, 'who');
    expect(q.questions[0].allowMultiple, isFalse);
    expect(q.questions[0].options.map((o) => o.id), ['self', 'others']);
    expect(q.questions[1].prompt, '先做哪几件？');
    expect(q.questions[1].allowMultiple, isTrue);
    expect(q.questions[1].options.map((o) => o.label), ['分类', '去重']);
  });

  test('tryParse rejects empty or prompt-less payloads', () {
    expect(AskUserQuestionnaire.tryParse({}), isNull);
    expect(AskUserQuestionnaire.tryParse({'questions': []}), isNull);
    expect(
      AskUserQuestionnaire.tryParse({
        'questions': [
          {'id': 'x', 'options': []},
        ],
      }),
      isNull,
    );
  });

  test('submission json matches tool contract', () {
    final ok = AskUserSubmission.ok([
      const AskUserAnswer(
        id: 'who',
        selectedIds: ['self'],
      ),
      const AskUserAnswer(
        id: 'note',
        selectedIds: [],
        customText: '给同事用',
      ),
    ]);
    expect(ok.toToolResult(), {
      'ok': true,
      'answers': [
        {'id': 'who', 'selected_ids': ['self']},
        {'id': 'note', 'selected_ids': [], 'custom_text': '给同事用'},
      ],
    });

    final cancelled = const AskUserSubmission.cancelled('用户取消');
    expect(cancelled.toToolResult()['ok'], isFalse);
    expect(cancelled.toToolResult()['cancelled'], isTrue);
  });

  test('host present then cancelAll unblocks with cancelled', () async {
    final host = AskUserHost();
    final future = host.present(
      const AskUserQuestionnaire(
        questions: [
          AskUserQuestion(
            id: 'q1',
            prompt: '？',
            allowMultiple: false,
            options: [AskUserOption(id: 'a', label: 'A')],
          ),
        ],
      ),
    );
    expect(host.pending.value, isNotNull);
    host.cancelAll();
    final result = await future;
    expect(result.cancelled, isTrue);
    expect(host.pending.value, isNull);
    host.dispose();
  });
}
