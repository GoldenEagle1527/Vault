import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../core/http_util.dart';
import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../../core/tool.dart';
import '../retry_backoff.dart';
import 'request_builder.dart';
import 'response_transformer.dart';
import 'stream_decoder.dart';

final Logger _logger = Logger('GeminiClient');

class GeminiClient extends LLMClient {
  final String _apiKey;
  final Dio _client;
  final Duration timeout;
  final Duration connectTimeout;
  final String? proxyUrl;
  final int maxRetries;
  final int initialRetryDelayMs;
  final int maxRetryDelayMs;

  GeminiClient({
    required String apiKey,
    Dio? client,
    this.timeout = const Duration(seconds: 300),
    this.connectTimeout = const Duration(seconds: 60),
    this.proxyUrl,
    this.maxRetries = 3,
    this.initialRetryDelayMs = 5000,
    this.maxRetryDelayMs = 30000,
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
    final requestBody = buildGeminiRequestBody(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
    );
    final model = modelConfig.model;
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent';
    final retry = RetryBackoff(
      maxRetries: maxRetries,
      initialDelayMs: initialRetryDelayMs,
      maxDelayMs: maxRetryDelayMs,
    );

    Future<void> waitForRetry(String reason) async {
      await retry.wait((delayMs, retryNumber, retryLimit) {
        _logger.warning(
          'Gemini API: $reason. Retrying in ${delayMs}ms... '
          '(Attempt $retryNumber/$retryLimit)',
        );
      });
    }

    while (true) {
      try {
        _logger.info(
          'Sending request to Gemini, baseUrl: https://generativelanguage.googleapis.com, timeout: ${timeout.inSeconds} seconds, proxy:${proxyUrl ?? 'none'} ,message length: ${messages.length}, tools: ${tools?.length}, model: $model',
        );
        final startTime = DateTime.now();
        final response = await _client.post(
          url,
          data: requestBody,
          options: Options(
            sendTimeout: timeout,
            receiveTimeout: timeout,
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': _apiKey,
            },
            validateStatus: (code) => true,
          ),
          cancelToken: cancelToken,
        );
        final endTime = DateTime.now();
        _logger.info(
          'Received response from Gemini, status code: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds} ms',
        );

        if (response.statusCode == 200) {
          bool shouldRetry = false;
          String retryReason = '';
          final modelMessage = transformGeminiResponse(
            response.data,
            modelConfig,
          );
          if (modelMessage == null) {
            shouldRetry = true;
            retryReason = 'Gemini returned no candidates';
          } else {
            final stopReason = modelMessage.stopReason;
            if (stopReason == 'MALFORMED_FUNCTION_CALL' ||
                stopReason == 'OTHER') {
              shouldRetry = true;
              retryReason = 'Stop reason is $stopReason';
            } else {
              return modelMessage;
            }
          }
          if (shouldRetry) {
            if (retry.canRetry) {
              await waitForRetry(retryReason);
              continue;
            } else {
              throw Exception(retryReason);
            }
          }
        } else {
          if (isRetryableHttpStatus(response.statusCode)) {
            if (retry.canRetry) {
              await waitForRetry('Returned status code ${response.statusCode}');
              continue;
            }
          }
          throw Exception(
            'Failed to generate from Gemini: ${response.statusCode} ${response.statusMessage} ${response.data}',
          );
        }
      } on DioException catch (error) {
        if (retry.canRetry) {
          await waitForRetry('DioException: ${error.message}');
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
    final model = modelConfig.model;
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/$model:streamGenerateContent';
    final requestBody = buildGeminiRequestBody(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
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
          'Gemini Stream API: $reason. Retrying in ${delayMs}ms... '
          '(Attempt $retryNumber/$retryLimit)',
        );
      });
    }

    void pumpStream() async {
      while (true) {
        try {
          _logger.info(
            'Sending streaming request to Gemini, baseUrl: https://generativelanguage.googleapis.com, timeout: ${timeout.inSeconds} seconds, proxy:${proxyUrl ?? 'none'} ,message length: ${messages.length}, tools: ${tools?.length}, model: $model',
          );
          final startTime = DateTime.now();
          final response = await _client.post(
            url,
            data: requestBody,
            options: Options(
              responseType: ResponseType.stream,
              sendTimeout: timeout,
              receiveTimeout: timeout,
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': _apiKey,
              },
              validateStatus: (code) => true,
            ),
            cancelToken: cancelToken,
          );
          final endTime = DateTime.now();
          _logger.info(
            'Received streaming response from Gemini, status code: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds} ms',
          );

          if (response.statusCode != 200) {
            if (isRetryableHttpStatus(response.statusCode)) {
              if (retry.canRetry) {
                await waitForRetry(
                  'Returned status code ${response.statusCode}',
                );
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
            }
            final responseBody = await utf8.decodeStream(
              (response.data.stream as Stream).cast<List<int>>(),
            );
            throw Exception(
              'Failed to stream from Gemini: ${response.statusCode} ${response.statusMessage} $responseBody',
            );
          }

          final byteStream = (response.data.stream as Stream).cast<List<int>>();
          final transformedStream = byteStream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .transform(GeminiChunkDecoder())
              .map((data) => transformGeminiResponse(data, modelConfig));

          bool retryNeeded = false;
          String? stopReason;
          await for (final message in transformedStream) {
            if (message == null) continue;
            stopReason = message.stopReason;
            if (stopReason != null &&
                (stopReason == 'MALFORMED_FUNCTION_CALL' ||
                    stopReason == 'OTHER')) {
              retryNeeded = true;
              break;
            }
            controller.add(StreamingMessage(modelMessage: message));
          }

          if (retryNeeded) {
            if (retry.canRetry) {
              await waitForRetry('Stop reason:$stopReason unexcepted');
              controller.add(
                StreamingMessage(
                  controlMessage: StreamingControlMessage(
                    controlFlag: StreamingControlFlag.retry,
                    data: {'retryReason': 'Stop reason:$stopReason unexcepted'},
                  ),
                ),
              );
              continue;
            } else {
              _logger.warning(
                'Gemini Stream API returned stop reason:$stopReason, but max retries reached.',
              );
            }
          }

          controller.close();
          break;
        } on DioException catch (error) {
          if (retry.canRetry) {
            await waitForRetry('DioException: ${error.message}');
            controller.add(
              StreamingMessage(
                controlMessage: StreamingControlMessage(
                  controlFlag: StreamingControlFlag.retry,
                  data: {'retryReason': 'DioException: ${error.message}'},
                ),
              ),
            );
            continue;
          }
          controller.addError(error);
          controller.close();
          break;
        } catch (error) {
          controller.addError(error);
          controller.close();
          break;
        }
      }
    }

    pumpStream();
    return controller.stream;
  }
}
