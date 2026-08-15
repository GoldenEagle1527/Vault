import 'dart:convert';

import 'package:vault/agent/ask_user.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// Interactive questionnaire. Blocks until the user submits or cancels in the UI.
Tool createAskUserTool(AskUserHost host, {Future<void> Function()? onPresent}) {
  return Tool(
    name: kAskUserToolName,
    description:
        '向用户展示选择题，等他们在 App 里点选（或自己填写）后再继续。'
        '需要澄清需求、让用户做选择时必须用这个工具，不要在聊天正文里直接提问或列选项。'
        '一次 1–4 个问题；每个问题给 2–5 个短选项。程序会自动加「自己填写」。'
        '调用后等待返回的 answers，再根据选择继续。',
    parameterMode: ToolParameterMode.object,
    allowBackground: false,
    parameters: {
      'type': 'object',
      'properties': {
        'questions': {
          'type': 'array',
          'description': '要问的问题列表，按展示顺序。',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string', 'description': '问题稳定 id，如 who / device'},
              'prompt': {'type': 'string', 'description': '用人话写的问题，不要用术语'},
              'allow_multiple': {
                'type': 'boolean',
                'description': 'true 为可多选，默认 false 单选',
              },
              'options': {
                'type': 'array',
                'description': '预设选项。不要包含「自己填写」，界面会自动加。',
                'items': {
                  'type': 'object',
                  'properties': {
                    'id': {'type': 'string'},
                    'label': {'type': 'string'},
                  },
                  'required': ['id', 'label'],
                },
              },
            },
            'required': ['prompt', 'options'],
          },
        },
      },
      'required': ['questions'],
    },
    executable: (Map<String, dynamic> args) async {
      final questionnaire = AskUserQuestionnaire.tryParse(args);
      if (questionnaire == null) {
        return jsonEncode({
          'ok': false,
          'error': 'questions 无效：至少要有一个带 prompt 的问题',
        });
      }
      await onPresent?.call();
      final submission = await host.present(questionnaire);
      return jsonEncode(submission.toToolResult());
    },
  );
}
