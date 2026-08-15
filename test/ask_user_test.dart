import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/agent/ask_user.dart';
import 'package:vault/agent/conversation_store.dart';
import 'package:vault/agent/project_store.dart';
import 'package:vault/agent/vault_meta_db.dart';
import 'package:vault/widgets/ask_user_panel.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

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
          'options': [
            '分类',
            {'id': 'dup', 'text': '去重'},
          ],
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
      const AskUserAnswer(id: 'who', selectedIds: ['self']),
      const AskUserAnswer(id: 'note', selectedIds: [], customText: '给同事用'),
    ]);
    expect(ok.toToolResult(), {
      'ok': true,
      'answers': [
        {
          'id': 'who',
          'selected_ids': ['self'],
        },
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

  test('tryParseArguments and tryParseResult round-trip transcript', () {
    const args = '''
{"questions":[{"id":"who","prompt":"给谁用？","options":[{"id":"self","label":"自己"},{"id":"others","label":"别人"}]}]}
''';
    final q = AskUserQuestionnaire.tryParseArguments(args);
    expect(q, isNotNull);
    expect(q!.questions.single.prompt, '给谁用？');

    final result = jsonEncode(
      AskUserSubmission.ok(const [
        AskUserAnswer(id: 'who', selectedIds: ['self'], customText: '同事'),
      ]).toToolResult(),
    );
    final answers = AskUserAnswer.tryParseResult(result);
    expect(answers, hasLength(1));
    expect(answers.single.selectedIds, ['self']);
    expect(answers.single.customText, '同事');

    final text = formatAskUserTranscript(questionnaire: q, answers: answers);
    expect(text, contains('给谁用？'));
    expect(text, contains('自己'));
    expect(text, contains('同事'));
  });

  testWidgets('AskUserPanel prefills initialAnswers', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AskUserPanel(
            questionnaire: const AskUserQuestionnaire(
              questions: [
                AskUserQuestion(
                  id: 'who',
                  prompt: '给谁用？',
                  allowMultiple: false,
                  options: [
                    AskUserOption(id: 'self', label: '自己'),
                    AskUserOption(id: 'others', label: '别人'),
                  ],
                ),
              ],
            ),
            initialAnswers: const [
              AskUserAnswer(
                id: 'who',
                selectedIds: ['self'],
                customText: '给同事用',
              ),
            ],
            onSubmit: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.radio_button_checked), findsWidgets);
    expect(find.text('给同事用'), findsOneWidget);
    expect(find.text('选好了'), findsOneWidget);
  });

  test('fork keeps ask_user call and replaces the tool result', () async {
    final temp = await Directory.systemTemp.createTemp('vault_ask_fork_');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final metaDb = VaultMetaDb.at(p.join(temp.path, 'vault_meta.db'));
    final projects = ProjectStore.local(
      metaDbPath: metaDb.filePath,
      guestRoot: p.join(temp.path, 'guest'),
    );
    final store = ConversationStore(metaDb: metaDb);
    final created = await projects.createProject(
      'ws1',
      conversationStore: store,
    );
    final opened = await store.ensureActive('ws1', created.path);
    final args = jsonEncode({
      'questions': [
        {
          'id': 'who',
          'prompt': '给谁用？',
          'options': [
            {'id': 'self', 'label': '自己'},
            {'id': 'others', 'label': '别人'},
          ],
        },
      ],
    });
    final oldResult = jsonEncode(
      AskUserSubmission.ok(const [
        AskUserAnswer(id: 'who', selectedIds: ['self']),
      ]).toToolResult(),
    );
    final parent = opened.state;
    parent.history.messages.addAll([
      UserMessage.text('做个工具'),
      ModelMessage(
        model: 'm',
        functionCalls: [
          FunctionCall(id: 'ask1', name: kAskUserToolName, arguments: args),
        ],
      ),
      FunctionExecutionResultMessage(
        results: [
          FunctionExecutionResult(
            id: 'ask1',
            name: kAskUserToolName,
            isError: false,
            arguments: args,
            content: [TextPart(oldResult)],
          ),
        ],
      ),
      ModelMessage(model: 'm', textOutput: '好的，给自己用'),
    ]);
    await store.save('ws1', created.path, parent);

    final newAnswers = const [
      AskUserAnswer(id: 'who', selectedIds: ['others']),
    ];
    final forked = await store.fork(
      workspaceId: 'ws1',
      projectPath: created.path,
      parentState: parent,
      keepCount: 2,
      forkedFromMessageIndex: 2,
      mutate: (state) {
        state.history.messages.add(
          FunctionExecutionResultMessage(
            results: [
              FunctionExecutionResult(
                id: 'ask1',
                name: kAskUserToolName,
                isError: false,
                arguments: args,
                content: [
                  TextPart(
                    jsonEncode(AskUserSubmission.ok(newAnswers).toToolResult()),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );

    expect(forked.state.history.messages, hasLength(3));
    expect(forked.state.history.messages[1], isA<ModelMessage>());
    final result =
        forked.state.history.messages[2] as FunctionExecutionResultMessage;
    final text = result.results.single.content
        .whereType<TextPart>()
        .map((p) => p.text)
        .join();
    expect(text, contains('others'));
    expect(text, isNot(contains('self')));
    expect(
      forked.index.conversations
          .firstWhere((c) => c.id == forked.state.sessionId)
          .parentId,
      parent.sessionId,
    );

    final original = await store.load('ws1', created.path, parent.sessionId);
    expect(original.history.messages, hasLength(4));
    final oldText =
        (original.history.messages[2] as FunctionExecutionResultMessage)
            .results
            .single
            .content
            .whereType<TextPart>()
            .map((p) => p.text)
            .join();
    expect(oldText, contains('self'));
  });
}
