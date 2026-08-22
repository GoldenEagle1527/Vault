import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:vault_agent_core/src/core/llm_client.dart';
import 'package:vault_agent_core/src/core/message.dart';
import 'package:vault_agent_core/src/core/tool.dart';
import 'package:vault_agent_core/src/llm/gemini/request_builder.dart';
import 'package:vault_agent_core/src/llm/gemini/response_transformer.dart';
import 'package:vault_agent_core/src/llm/gemini/stream_decoder.dart';
import 'package:vault_agent_core/src/llm/gemini_client.dart' as legacy;

void main() {
  test('legacy facade keeps client and decoder symbols available', () {
    expect(legacy.GeminiClient(apiKey: 'test-key'), isA<legacy.GeminiClient>());
    expect(legacy.GeminiChunkDecoder(), isA<legacy.GeminiChunkDecoder>());
  });

  group('Gemini request builder', () {
    test(
      'preserves generation, tool, multimodal, and thought serialization',
      () {
        final body = buildGeminiRequestBody(
          [
            SystemMessage('system one'),
            SystemMessage('system two'),
            UserMessage([
              TextPart('hello'),
              ImagePart('image-data', 'image/png'),
            ]),
            ModelMessage(
              model: 'gemini-test',
              textOutput: 'calling',
              thoughtSignature: 'signature',
              functionCalls: [
                FunctionCall(
                  id: 'call-1',
                  name: 'lookup',
                  arguments: '{"query":"dart"}',
                ),
              ],
            ),
            FunctionExecutionResultMessage(
              results: [
                FunctionExecutionResult(
                  id: 'call-1',
                  name: 'lookup',
                  isError: false,
                  arguments: '{"query":"dart"}',
                  content: [
                    TextPart('first'),
                    TextPart('second'),
                    AudioPart('audio-data', 'audio/wav'),
                  ],
                ),
              ],
            ),
          ],
          tools: [
            Tool(
              name: 'lookup',
              description: 'Looks things up',
              parameters: {
                'type': 'object',
                'properties': {
                  'query': {'type': 'string'},
                },
              },
            ),
          ],
          toolChoice: ToolChoice(
            mode: ToolChoiceMode.required,
            allowedFunctionNames: ['lookup'],
          ),
          modelConfig: ModelConfig(
            model: 'gemini-test',
            temperature: 0.2,
            maxTokens: 128,
            topP: 0.9,
            topK: 20,
            extra: {
              'thinkingConfig': {'thinkingBudget': 64},
            },
          ),
          jsonOutput: true,
        );

        expect(body['systemInstruction'], {
          'parts': [
            {'text': 'system one\nsystem two'},
          ],
        });
        expect(body['generationConfig'], {
          'temperature': 0.2,
          'maxOutputTokens': 128,
          'topP': 0.9,
          'topK': 20,
          'responseMimeType': 'application/json',
          'thinkingConfig': {'thinkingBudget': 64},
        });
        expect(body['toolConfig'], {
          'mode': 'ANY',
          'allowedFunctionNames': ['lookup'],
        });

        final contents = body['contents'] as List;
        expect(contents[0], {
          'role': 'user',
          'parts': [
            {'text': 'hello'},
            {
              'inlineData': {'mimeType': 'image/png', 'data': 'image-data'},
            },
          ],
        });
        expect((contents[1]['parts'] as List)[1], {
          'functionCall': {
            'id': 'call-1',
            'name': 'lookup',
            'args': {'query': 'dart'},
          },
          'thoughtSignature': 'signature',
        });
        expect((contents[2]['parts'] as List).single, {
          'functionResponse': {
            'id': 'call-1',
            'name': 'lookup',
            'response': {'content': 'first\nsecond'},
            'parts': [
              {
                'inlineData': {'mimeType': 'audio/wav', 'data': 'audio-data'},
              },
            ],
          },
        });
      },
    );
  });

  group('Gemini response transformer', () {
    test('preserves text, thoughts, calls, usage, and metadata', () {
      final usageMetadata = {
        'promptTokenCount': 3,
        'candidatesTokenCount': 5,
        'totalTokenCount': 10,
        'cachedContentTokenCount': 1,
        'thoughtsTokenCount': 2,
      };
      final message = transformGeminiResponse({
        'candidates': [
          {
            'content': {
              'parts': [
                {'thought': true, 'text': 'reason'},
                {'text': 'answer'},
                {
                  'functionCall': {
                    'name': 'lookup',
                    'args': {'query': 'dart'},
                  },
                  'thoughtSignature': 'part-signature',
                },
              ],
            },
            'finishReason': 'STOP',
            'thoughtSignature': 'candidate-signature',
          },
        ],
        'usageMetadata': usageMetadata,
        'modelVersion': 'gemini-version',
        'responseId': 'response-1',
        'promptFeedback': {'blockReason': null},
      }, ModelConfig(model: 'gemini-test'));

      expect(message!.textOutput, 'answer');
      expect(message.thought, 'reason');
      expect(message.thoughtSignature, 'candidate-signature');
      expect(message.functionCalls.single.id, 'lookup');
      expect(jsonDecode(message.functionCalls.single.arguments), {
        'query': 'dart',
      });
      expect(message.stopReason, 'STOP');
      expect(message.usage!.promptTokens, 3);
      expect(message.usage!.completionTokens, 5);
      expect(message.usage!.totalTokens, 10);
      expect(message.usage!.cachedToken, 1);
      expect(message.usage!.thoughtToken, 2);
      expect(message.usage!.originalUsage, same(usageMetadata));
      expect(message.metadata, {
        'modelVersion': 'gemini-version',
        'responseId': 'response-1',
        'promptFeedback': {'blockReason': null},
      });
    });

    test('keeps no-candidate and malformed-response semantics', () {
      expect(
        transformGeminiResponse({}, ModelConfig(model: 'gemini-test')),
        isNull,
      );
      expect(
        () => transformGeminiResponse({
          'candidates': [
            {'content': 'invalid'},
          ],
        }, ModelConfig(model: 'gemini-test')),
        throwsA(
          predicate(
            (error) => error.toString().startsWith(
              'Exception: Unexpected response format from Gemini:',
            ),
          ),
        ),
      );
    });
  });

  group('Gemini stream decoder', () {
    test('decodes array framing and multi-line chunks', () async {
      final source = Stream<String>.fromIterable([
        '[',
        '{"candidates": [',
        '{"content": {"parts": [{"text": "one"}]}}',
        ']},',
        '{"candidates":[{"content":{"parts":[{"text":"two"}]}}]}',
        ']',
      ]);

      final chunks = await source.transform(GeminiChunkDecoder()).toList();

      expect(chunks, hasLength(2));
      expect(
        chunks.map(
          (chunk) => chunk['candidates'][0]['content']['parts'][0]['text'],
        ),
        ['one', 'two'],
      );
    });

    test('skips malformed chunks and continues decoding', () async {
      final chunks = await Stream<String>.fromIterable([
        '{not-json}',
        '{"ok":true}',
      ]).transform(GeminiChunkDecoder()).toList();

      expect(chunks, [
        {'ok': true},
      ]);
    });
  });
}
