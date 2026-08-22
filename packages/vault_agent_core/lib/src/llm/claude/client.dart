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

/// Client for the Anthropic Messages API (direct, not via AWS Bedrock).
///
/// Uses `x-api-key` header authentication and SSE for streaming.
///
/// ```dart
/// final client = ClaudeClient(
///   apiKey: Platform.environment['ANTHROPIC_API_KEY'] ?? '',
/// );
/// ```
class ClaudeClient extends LLMClient {
  final Logger _logger = Logger('ClaudeClient');
  final String _apiKey;
  final Dio _client;
  final ClaudeRequestBuilder _requestBuilder;
  final ClaudeResponseTransformer _responseTransformer;
  final ClaudeStreamDecoder _streamDecoder;

  final String baseUrl;
  final String anthropicVersion;
  final Duration timeout;
  final String? proxyUrl;
  final int maxRetries;
  final int initialRetryDelayMs;
  final int maxRetryDelayMs;

  ClaudeClient({
    required String apiKey,
    this.baseUrl = 'https://api.anthropic.com',
    this.anthropicVersion = '2023-06-01',
    Dio? client,
    this.timeout = const Duration(seconds: 300),
    this.proxyUrl,
    this.maxRetries = 3,
    this.initialRetryDelayMs = 1000,
    this.maxRetryDelayMs = 10000,
  }) : _apiKey = apiKey,
       _client = client ?? Dio(),
       _requestBuilder = ClaudeRequestBuilder(),
       _responseTransformer = ClaudeResponseTransformer(),
       _streamDecoder = ClaudeStreamDecoder() {
    configureProxy(_client, proxyUrl);
  }

  Map<String, String> get _headers => {
    'x-api-key': _apiKey,
    'anthropic-version': anthropicVersion,
    'content-type': 'application/json',
  };

  Future<void> _waitForRetry(RetryBackoff retry, String reason) async {
    await retry.wait((delayMs, retryNumber, retryLimit) {
      _logger.warning(
        'Claude API: $reason. Retrying in ${delayMs}ms... '
        '(Attempt $retryNumber/$retryLimit)',
      );
    });
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
    final body = _requestBuilder.build(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
    );
    final url = '$baseUrl/v1/messages';

    final retry = RetryBackoff(
      maxRetries: maxRetries,
      initialDelayMs: initialRetryDelayMs,
      maxDelayMs: maxRetryDelayMs,
    );
    while (true) {
      try {
        _logger.info(
          'Sending request to Claude API, baseUrl: $baseUrl, timeout: ${timeout.inSeconds}s, proxy: ${proxyUrl ?? 'none'}, messages: ${messages.length}, tools: ${tools?.length}, model: ${modelConfig.model}',
        );
        final startTime = DateTime.now();
        final response = await _client.post(
          url,
          data: jsonEncode(body),
          options: Options(
            headers: _headers,
            responseType: ResponseType.json,
            sendTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (status) => true,
          ),
          cancelToken: cancelToken,
        );
        final endTime = DateTime.now();
        _logger.info(
          'Received response from Claude API, status: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds}ms',
        );

        if (response.statusCode == 200) {
          return _responseTransformer.transform(response.data, modelConfig);
        }

        if (isRetryableHttpStatus(response.statusCode)) {
          if (retry.canRetry) {
            await _waitForRetry(retry, 'Status ${response.statusCode}');
            continue;
          }
        }

        throw Exception(
          'Claude API Error: ${response.statusCode} ${response.data}',
        );
      } on DioException catch (e) {
        if (retry.canRetry) {
          await _waitForRetry(retry, 'DioException: ${e.message}');
          continue;
        }
        final errorMsg = e.response?.data ?? e.message;
        _logger.warning('Claude API Error (${e.response?.statusCode})');
        throw Exception('Claude API Error: $errorMsg');
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
    final body = _requestBuilder.build(
      messages,
      tools: tools,
      toolChoice: toolChoice,
      modelConfig: modelConfig,
      jsonOutput: jsonOutput,
    );
    body['stream'] = true;
    final url = '$baseUrl/v1/messages';

    final retry = RetryBackoff(
      maxRetries: maxRetries,
      initialDelayMs: initialRetryDelayMs,
      maxDelayMs: maxRetryDelayMs,
    );
    while (true) {
      try {
        _logger.info(
          'Sending streaming request to Claude API, baseUrl: $baseUrl, timeout: ${timeout.inSeconds}s, proxy: ${proxyUrl ?? 'none'}, messages: ${messages.length}, tools: ${tools?.length}, model: ${modelConfig.model}',
        );
        final startTime = DateTime.now();
        final response = await _client.post(
          url,
          data: jsonEncode(body),
          options: Options(
            headers: _headers,
            responseType: ResponseType.stream,
            sendTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (status) => true,
          ),
          cancelToken: cancelToken,
        );
        final endTime = DateTime.now();
        _logger.info(
          'Received streaming response from Claude API, status: ${response.statusCode}, duration: ${endTime.difference(startTime).inMilliseconds}ms',
        );

        if (response.statusCode == 200) {
          final stream = (response.data.stream as Stream).cast<List<int>>();
          return _streamDecoder.decode(stream, modelConfig);
        }

        if (isRetryableHttpStatus(response.statusCode)) {
          if (retry.canRetry) {
            await _waitForRetry(retry, 'Status ${response.statusCode}');
            continue;
          }
        }

        final errorBody = await utf8.decodeStream(
          (response.data.stream as Stream).cast<List<int>>(),
        );
        throw Exception(
          'Claude Stream API Error: ${response.statusCode} $errorBody',
        );
      } catch (e) {
        if (e is DioException) {
          if (retry.canRetry) {
            await _waitForRetry(retry, 'DioException: ${e.message}');
            continue;
          }
          final errorMsg = e.response?.data ?? e.message;
          _logger.warning('Claude Stream Error (${e.response?.statusCode})');
          throw Exception('Claude Stream Error: $errorMsg');
        }
        rethrow;
      }
    }
  }
}
