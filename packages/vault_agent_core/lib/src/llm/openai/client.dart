import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../core/http_util.dart';
import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../../core/tool.dart';
import 'request_builder.dart';
import '../retry_backoff.dart';
import 'stream_decoder.dart';

class OpenAIClient extends LLMClient {
  final Logger _logger = Logger('OpenAIClient');
  final String _apiKey;
  final String baseUrl;
  final Dio _client;
  final Duration timeout;
  final Duration connectTimeout;
  final String? proxyUrl;
  final int maxRetries;
  final int initialRetryDelayMs;
  final int maxRetryDelayMs;

  OpenAIClient({
    required String apiKey,
    this.baseUrl = 'https://api.openai.com',
    this.timeout = const Duration(seconds: 300),
    this.connectTimeout = const Duration(seconds: 60),
    this.proxyUrl,
    this.maxRetries = 3,
    this.initialRetryDelayMs = 1000,
    this.maxRetryDelayMs = 10000,
    Dio? client,
  }) : _apiKey = apiKey,
       _client = client ?? Dio() {
    configureProxy(_client, proxyUrl);
    _client.options.connectTimeout = connectTimeout;
  }

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    final url = '$baseUrl/chat/completions';
    final body = OpenAIRequestBuilder.build(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
    );

    final retry = RetryBackoff(
      maxRetries: maxRetries,
      initialDelayMs: initialRetryDelayMs,
      maxDelayMs: maxRetryDelayMs,
    );

    Future<void> waitForRetry(String reason) async {
      await retry.wait((delayMs, retryNumber, retryLimit) {
        _logger.warning(
          'OpenAI API: $reason. Retrying in ${delayMs}ms... '
          '(Attempt $retryNumber/$retryLimit)',
        );
      });
    }

    while (true) {
      try {
        _logger.info(
          'Sending request to OpenAI (Attempt ${retry.retryCount + 1}), '
          'baseUrl: $baseUrl, timeout: ${timeout.inSeconds} seconds, '
          "proxy:${proxyUrl ?? 'none'} , message length: ${messages.length}, "
          'tools: ${tools?.length}, model: ${modelConfig.model}',
        );
        final startTime = DateTime.now();
        final response = await _client.post(
          url,
          data: body,
          options: Options(
            sendTimeout: timeout,
            receiveTimeout: timeout,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $_apiKey',
            },
            validateStatus: (code) => true,
          ),
          cancelToken: cancelToken,
        );
        final endTime = DateTime.now();
        _logger.info(
          'Received response from OpenAI, status code: ${response.statusCode}, '
          'duration: ${endTime.difference(startTime).inMilliseconds} ms',
        );
        if (response.statusCode == 200) {
          final data = response.data is String
              ? jsonDecode(response.data)
              : response.data;
          return _parseResponse(data, modelConfig);
        }
        if (isRetryableHttpStatus(response.statusCode) && retry.canRetry) {
          await waitForRetry('Returned status code ${response.statusCode}');
          continue;
        }
        throw Exception(
          'Failed to generate from OpenAI: ${response.statusCode} '
          '${response.statusMessage} ${response.data}',
        );
      } on DioException catch (e) {
        if (retry.canRetry) {
          await waitForRetry('DioException: ${e.message}');
          continue;
        }
        rethrow;
      }
    }
  }

  @override
  Future<Stream<StreamingMessage>> stream(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    final url = '$baseUrl/chat/completions';
    final body = OpenAIRequestBuilder.build(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      stream: true,
      jsonOutput: jsonOutput,
    );

    final controller = StreamController<StreamingMessage>();
    final retry = RetryBackoff(
      maxRetries: maxRetries,
      initialDelayMs: initialRetryDelayMs,
      maxDelayMs: maxRetryDelayMs,
    );

    Future<void> waitForRetry(String reason) async {
      await retry.wait((delayMs, retryNumber, retryLimit) {
        _logger.warning(
          'OpenAI Stream API: $reason. Retrying in ${delayMs}ms... '
          '(Attempt $retryNumber/$retryLimit)',
        );
      });
    }

    void pumpStream() async {
      while (true) {
        try {
          _logger.info(
            'Sending streaming request to OpenAI, baseUrl: $baseUrl, '
            'timeout: ${timeout.inSeconds} seconds, '
            "proxy:${proxyUrl ?? 'none'}, message length: ${messages.length}, "
            'tools: ${tools?.length}, model: ${modelConfig.model}',
          );
          final startTime = DateTime.now();
          final response = await _client.post(
            url,
            data: body,
            options: Options(
              responseType: ResponseType.stream,
              sendTimeout: timeout,
              receiveTimeout: timeout,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $_apiKey',
              },
              validateStatus: (code) => true,
            ),
            cancelToken: cancelToken,
          );
          final endTime = DateTime.now();

          _logger.info(
            'Received streaming response from OpenAI, status code: '
            '${response.statusCode}, duration: '
            '${endTime.difference(startTime).inMilliseconds} ms',
          );

          if (response.statusCode != 200) {
            if (isRetryableHttpStatus(response.statusCode) && retry.canRetry) {
              await waitForRetry('Returned status code ${response.statusCode}');
              controller.add(
                StreamingMessage(
                  controlMessage: StreamingControlMessage(
                    controlFlag: StreamingControlFlag.retry,
                    data: {
                      'retryReason':
                          'Returned status code ${response.statusCode}',
                    },
                  ),
                ),
              );
              continue;
            }

            final responseBody = await utf8.decodeStream(
              (response.data.stream as Stream).cast<List<int>>(),
            );
            throw Exception(
              'Failed to stream from OpenAI: ${response.statusCode} '
              '${response.statusMessage} $responseBody',
            );
          }

          final stream = (response.data.stream as Stream).cast<List<int>>();
          final transformedStream = stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .transform(OpenAIChunkDecoder())
              .transform(OpenAIResponseTransformer(modelConfig))
              .map((chunk) => StreamingMessage(modelMessage: chunk));

          await for (final message in transformedStream) {
            controller.add(message);
          }

          controller.close();
          break;
        } on DioException catch (e) {
          if (retry.canRetry) {
            await waitForRetry('DioException: ${e.message}');
            controller.add(
              StreamingMessage(
                controlMessage: StreamingControlMessage(
                  controlFlag: StreamingControlFlag.retry,
                  data: {'retryReason': 'DioException: ${e.message}'},
                ),
              ),
            );
            continue;
          }
          controller.addError(e);
          controller.close();
          break;
        } catch (e) {
          controller.addError(e);
          controller.close();
          break;
        }
      }
    }

    pumpStream();
    return controller.stream;
  }
}

ModelMessage _parseResponse(
  Map<String, dynamic> data,
  ModelConfig modelConfig,
) {
  try {
    final choices = data['choices'] as List? ?? [];
    if (choices.isEmpty) {
      return ModelMessage(textOutput: '', model: modelConfig.model);
    }

    final choice = choices[0];
    final message = choice['message'];
    final content = message['content'];
    final reasoningContent = message['reasoning_content'] as String?;
    final audio = message['audio'];
    final toolCalls = message['tool_calls'] as List? ?? [];
    final finishReason = choice['finish_reason'];

    final functionCalls = <FunctionCall>[];
    for (final tc in toolCalls) {
      if (tc['type'] == 'function') {
        final fn = tc['function'];
        functionCalls.add(
          FunctionCall(
            id: tc['id'],
            name: fn['name'],
            arguments: fn['arguments'],
          ),
        );
      }
    }

    ModelUsage? usage;
    if (data['usage'] != null) {
      final u = data['usage'];
      usage = ModelUsage(
        promptTokens: u['prompt_tokens'] ?? 0,
        completionTokens: u['completion_tokens'] ?? 0,
        totalTokens: u['total_tokens'] ?? 0,
        cachedToken: u['prompt_tokens_details']?['cached_tokens'] ?? 0,
        thoughtToken: u['completion_tokens_details']?['reasoning_tokens'] ?? 0,
        originalUsage: u,
        model: modelConfig.model,
      );
    }

    final audioOutputs = <ModelAudioPart>[];
    if (audio != null) {
      audioOutputs.add(
        ModelAudioPart(
          base64Data: audio['data'],
          transcript: audio['transcript'],
          metadata: {'expires_at': audio['expires_at'], 'id': audio['id']},
        ),
      );
    }

    final metadata = {
      'model': data['model'],
      'object': data['object'],
      'created': data['created'],
      'usage': data['usage'],
      'prompt_filter_results': data['prompt_filter_results'],
      'system_fingerprint': data['system_fingerprint'],
    };

    return ModelMessage(
      thought: reasoningContent,
      textOutput: content,
      audioOutputs: audioOutputs,
      functionCalls: functionCalls,
      usage: usage,
      metadata: metadata,
      stopReason: finishReason,
      model: modelConfig.model,
    );
  } catch (_) {
    throw Exception('Unexpected response format from OpenAI: $data');
  }
}
