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
import 'stream_response_transformer.dart';

class ResponsesClient extends LLMClient {
  final Logger _logger = Logger('ResponsesClient');
  final String _apiKey;
  final String baseUrl;
  final Dio _client;
  final Duration timeout;
  final Duration connectTimeout;
  final String? proxyUrl;
  final int maxRetries;
  final int initialRetryDelayMs;
  final int maxRetryDelayMs;

  /// When true (default), derives `previous_response_id` from the last model
  /// message carrying a response ID and sends only messages after it.
  final bool autoPreviousResponseId;

  /// Extra model configuration keys allowed into the API request body.
  final Set<String>? extraAllowedKeys;

  ResponsesClient({
    required String apiKey,
    this.baseUrl = 'https://api.openai.com',
    this.timeout = const Duration(seconds: 300),
    this.connectTimeout = const Duration(seconds: 60),
    this.proxyUrl,
    this.maxRetries = 3,
    this.initialRetryDelayMs = 1000,
    this.maxRetryDelayMs = 10000,
    this.autoPreviousResponseId = true,
    this.extraAllowedKeys,
    Dio? client,
  }) : _apiKey = apiKey,
       _client = client ?? Dio() {
    configureProxy(_client, proxyUrl);
    _client.options.connectTimeout = connectTimeout;
  }

  ResponsesRequestBuilder get _requestBuilder => ResponsesRequestBuilder(
    autoPreviousResponseId: autoPreviousResponseId,
    extraAllowedKeys: extraAllowedKeys,
  );

  @override
  Future<ModelMessage> generate(
    List<LLMMessage> messages, {
    List<Tool>? tools,
    ToolChoice? toolChoice,
    required ModelConfig modelConfig,
    bool? jsonOutput,
    CancelToken? cancelToken,
  }) async {
    final body = _requestBuilder.build(
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
          'Responses API: $reason. Retrying in ${delayMs}ms... '
          '(Attempt $retryNumber/$retryLimit)',
        );
      });
    }

    while (true) {
      try {
        _logger.info(
          'Sending request to OpenAI Responses API '
          '(Attempt ${retry.retryCount + 1}), baseUrl: $baseUrl, '
          'timeout: ${timeout.inSeconds} seconds, proxy:${proxyUrl ?? 'none'} '
          ', message length: ${messages.length}, tools: ${tools?.length}, '
          'model: ${modelConfig.model}',
        );
        final startTime = DateTime.now();
        final response = await _client.post(
          '$baseUrl/responses',
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
        _logger.info(
          'Received response from OpenAI Responses API, status code: '
          '${response.statusCode}, duration: '
          '${DateTime.now().difference(startTime).inMilliseconds} ms',
        );

        if (response.statusCode == 200) {
          final data = response.data is String
              ? jsonDecode(response.data)
              : response.data;
          return ResponsesResponseTransformer(
            modelConfig,
          ).transform(data as Map<String, dynamic>);
        }
        if (isRetryableHttpStatus(response.statusCode) && retry.canRetry) {
          await waitForRetry('Returned status code ${response.statusCode}');
          continue;
        }
        throw Exception(
          'Failed to generate from OpenAI Responses API: '
          '${response.statusCode} ${response.statusMessage} ${response.data}',
        );
      } on DioException catch (error) {
        if (retry.canRetry) {
          await waitForRetry('DioException: ${error.message}');
          continue;
        }
        rethrow;
      }
    }
  }

  /// Checks whether a response ID can be retrieved from the API.
  Future<bool> checkResponseId(String responseId) async {
    try {
      _logger.info('Checking responseId: $responseId');
      final response = await _client.get(
        '$baseUrl/responses/$responseId',
        options: Options(
          sendTimeout: connectTimeout,
          receiveTimeout: timeout,
          headers: {'Authorization': 'Bearer $_apiKey'},
          validateStatus: (code) => true,
        ),
      );
      if (response.statusCode == 200) {
        _logger.info('ResponseId $responseId is valid');
        return true;
      }
      if (response.statusCode == 404) {
        _logger.warning('ResponseId $responseId not found (404)');
        return false;
      }
      _logger.warning(
        'Unexpected status code ${response.statusCode} when checking '
        'responseId $responseId',
      );
      return false;
    } catch (error) {
      _logger.warning('Error checking responseId $responseId: $error');
      return false;
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
    final body = _requestBuilder.build(
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
          'Responses API Stream: $reason. Retrying in ${delayMs}ms... '
          '(Attempt $retryNumber/$retryLimit)',
        );
      });
    }

    Future<void> pumpStream() async {
      while (true) {
        try {
          _logger.info(
            'Sending streaming request to OpenAI Responses API, '
            'baseUrl: $baseUrl, timeout: ${timeout.inSeconds} seconds, '
            'proxy:${proxyUrl ?? 'none'}, message length: ${messages.length}, '
            'tools: ${tools?.length}, model: ${modelConfig.model}',
          );
          final startTime = DateTime.now();
          final response = await _client.post(
            '$baseUrl/responses',
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
          _logger.info(
            'Received streaming response from OpenAI Responses API, '
            'status code: ${response.statusCode}, duration: '
            '${DateTime.now().difference(startTime).inMilliseconds} ms',
          );

          if (response.statusCode != 200) {
            if (isRetryableHttpStatus(response.statusCode) && retry.canRetry) {
              final reason = 'Returned status code ${response.statusCode}';
              await waitForRetry(reason);
              controller.add(
                StreamingMessage(
                  controlMessage: StreamingControlMessage(
                    controlFlag: StreamingControlFlag.retry,
                    data: {'retryReason': reason},
                  ),
                ),
              );
              continue;
            }
            final responseBody = await utf8.decodeStream(
              (response.data.stream as Stream).cast<List<int>>(),
            );
            throw Exception(
              'Failed to stream from OpenAI Responses API: '
              '${response.statusCode} ${response.statusMessage} $responseBody',
            );
          }

          final transformedStream = (response.data.stream as Stream)
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .transform(ResponsesChunkDecoder())
              .transform(ResponsesAPIResponseTransformer(modelConfig))
              .map((chunk) => StreamingMessage(modelMessage: chunk));
          await for (final message in transformedStream) {
            controller.add(message);
          }
          await controller.close();
          break;
        } on DioException catch (error) {
          if (retry.canRetry) {
            final reason = 'DioException: ${error.message}';
            await waitForRetry(reason);
            controller.add(
              StreamingMessage(
                controlMessage: StreamingControlMessage(
                  controlFlag: StreamingControlFlag.retry,
                  data: {'retryReason': reason},
                ),
              ),
            );
            continue;
          }
          controller.addError(error);
          await controller.close();
          break;
        } catch (error) {
          controller.addError(error);
          await controller.close();
          break;
        }
      }
    }

    unawaited(pumpStream());
    return controller.stream;
  }
}
