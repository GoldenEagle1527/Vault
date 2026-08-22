import 'dart:async';
import 'dart:convert';

import 'package:aws_common/aws_common.dart';
import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../core/http_util.dart';
import '../../core/llm_client.dart';
import '../../core/message.dart';
import '../../core/tool.dart';
import '../retry_backoff.dart';
import 'aws_sigv4_signer.dart';
import 'event_stream_decoder.dart';
import 'request_builder.dart';
import 'response_transformer.dart';
import 'stream_parser.dart';

class BedrockClaudeClient extends LLMClient {
  BedrockClaudeClient({
    required this.region,
    required String accessKeyId,
    required String secretAccessKey,
    this.sessionToken,
    this.service = 'bedrock',
    Dio? client,
    this.timeout = const Duration(seconds: 300),
    this.proxyUrl,
    this.maxRetries = 3,
    this.initialRetryDelayMs = 1000,
    this.maxRetryDelayMs = 10000,
  }) : _client = client ?? Dio(),
       _signer = BedrockAwsSigV4Signer(
         accessKeyId: accessKeyId,
         secretAccessKey: secretAccessKey,
         sessionToken: sessionToken,
       ) {
    configureProxy(_client, proxyUrl);
  }

  final Logger _logger = Logger('BedrockClaudeClient');
  final String region;
  final String? sessionToken;
  final String? service;
  final Dio _client;
  final Duration timeout;
  final String? proxyUrl;
  final int maxRetries;
  final int initialRetryDelayMs;
  final int maxRetryDelayMs;
  final BedrockAwsSigV4Signer _signer;
  late final BedrockRequestBuilder _requestBuilder = BedrockRequestBuilder(
    logger: _logger,
  );
  final BedrockResponseTransformer _responseTransformer =
      BedrockResponseTransformer();

  Future<void> _waitForRetry(RetryBackoff retry, String reason) async {
    await retry.wait((delayMs, retryNumber, retryLimit) {
      _logger.warning(
        'Bedrock API: $reason. Retrying in ${delayMs}ms... '
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
    final bodyBytes = utf8.encode(
      jsonEncode(
        _requestBuilder.build(
          messages,
          tools: tools,
          toolChoice: toolChoice,
          modelConfig: modelConfig,
          jsonOutput: jsonOutput,
        ),
      ),
    );
    final url = _buildUrl(modelConfig.model, streaming: false);
    final signedRequest = await _signer.sign(
      _unsignedRequest(url, bodyBytes),
      region: region,
    );

    final retry = RetryBackoff(
      maxRetries: maxRetries,
      initialDelayMs: initialRetryDelayMs,
      maxDelayMs: maxRetryDelayMs,
    );
    while (true) {
      try {
        _logger.info(
          'Sending request to Bedrock, region: $region, '
          'timeout: ${timeout.inSeconds} seconds, '
          'proxy:${proxyUrl ?? 'none'} ,message length: ${messages.length}, '
          'tools: ${tools?.length}, model: ${modelConfig.model}',
        );
        final startTime = DateTime.now();
        final response = await _client.postUri(
          url,
          data: Stream.fromIterable([bodyBytes]),
          options: Options(
            headers: signedRequest.headers,
            responseType: ResponseType.json,
            sendTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (_) => true,
          ),
          cancelToken: cancelToken,
        );
        _logger.info(
          'Received response from Bedrock, status code: '
          '${response.statusCode}, duration: '
          '${DateTime.now().difference(startTime).inMilliseconds} ms',
        );
        if (response.statusCode == 200) {
          return _responseTransformer.transform(response.data, modelConfig);
        }
        if (isRetryableHttpStatus(response.statusCode) && retry.canRetry) {
          await _waitForRetry(retry, 'Status ${response.statusCode}');
          continue;
        }
        throw Exception(
          'Bedrock API Error: ${response.statusCode} ${response.data}',
        );
      } on DioException catch (error) {
        if (retry.canRetry) {
          await _waitForRetry(retry, 'DioException: ${error.message}');
          continue;
        }
        final errorMessage = error.response?.data ?? error.message;
        _logger.warning('Bedrock API Error (${error.response?.statusCode})');
        throw Exception('Bedrock API Error: $errorMessage');
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
    final bodyBytes = utf8.encode(
      jsonEncode(
        _requestBuilder.build(
          messages,
          tools: tools,
          toolChoice: toolChoice,
          modelConfig: modelConfig,
          jsonOutput: jsonOutput,
        ),
      ),
    );
    final url = _buildUrl(modelConfig.model, streaming: true);
    final signedRequest = await _signer.sign(
      _unsignedRequest(url, bodyBytes),
      region: region,
    );

    final retry = RetryBackoff(
      maxRetries: maxRetries,
      initialDelayMs: initialRetryDelayMs,
      maxDelayMs: maxRetryDelayMs,
    );
    while (true) {
      try {
        _logger.info(
          'Sending streaming request to Bedrock, region: $region, '
          'timeout: ${timeout.inSeconds} seconds, '
          'proxy:${proxyUrl ?? 'none'} ,message length: ${messages.length}, '
          'tools: ${tools?.length}, model: ${modelConfig.model}',
        );
        final startTime = DateTime.now();
        final response = await _client.postUri(
          url,
          data: Stream.fromIterable([bodyBytes]),
          options: Options(
            headers: signedRequest.headers,
            responseType: ResponseType.stream,
            sendTimeout: timeout,
            receiveTimeout: timeout,
            validateStatus: (_) => true,
          ),
          cancelToken: cancelToken,
        );
        _logger.info(
          'Received streaming response from Bedrock, status code: '
          '${response.statusCode}, duration: '
          '${DateTime.now().difference(startTime).inMilliseconds} ms',
        );

        if (response.statusCode == 200) {
          return _transformStream(
            (response.data.stream as Stream).cast<List<int>>(),
            modelConfig,
          );
        }
        if (isRetryableHttpStatus(response.statusCode) && retry.canRetry) {
          await _waitForRetry(retry, 'Status ${response.statusCode}');
          continue;
        }
        final errorBody = await utf8.decodeStream(
          (response.data.stream as Stream).cast<List<int>>(),
        );
        throw Exception(
          'Bedrock Stream API Error: ${response.statusCode} $errorBody',
        );
      } catch (error) {
        if (error is DioException) {
          if (retry.canRetry) {
            await _waitForRetry(retry, 'DioException: ${error.message}');
            continue;
          }
          final errorMessage = error.response?.data ?? error.message;
          _logger.warning(
            'Bedrock Stream Error (${error.response?.statusCode})',
          );
          throw Exception('Bedrock Stream Error: $errorMessage');
        }
        rethrow;
      }
    }
  }

  Stream<StreamingMessage> _transformStream(
    Stream<List<int>> stream,
    ModelConfig modelConfig,
  ) {
    final controller = StreamController<StreamingMessage>();
    final parser = BedrockStreamParser(modelConfig);
    stream
        .transform(EventStreamDecoder())
        .listen(
          (event) {
            final eventType = event.headers[':event-type'];
            if (eventType == 'chunk') {
              try {
                final payload = jsonDecode(event.payloadAsString);
                final bytes = base64Decode(payload['bytes']);
                final chunkJson =
                    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
                final message = parser.parse(chunkJson);
                if (message != null) {
                  controller.add(StreamingMessage(modelMessage: message));
                }
              } catch (error) {
                _logger.warning('Error parsing chunk: $error');
              }
            } else if (eventType == 'exception') {
              final payload = jsonDecode(event.payloadAsString);
              controller.addError(
                Exception('Bedrock Stream Exception: ${payload['message']}'),
              );
            }
          },
          onError: controller.addError,
          onDone: controller.close,
        );
    return controller.stream;
  }

  Uri _buildUrl(String model, {required bool streaming}) {
    final modelId = Uri.encodeComponent(model);
    final operation = streaming ? 'invoke-with-response-stream' : 'invoke';
    return Uri.parse(
      'https://bedrock-runtime.$region.amazonaws.com/'
      'model/$modelId/$operation',
    );
  }

  AWSHttpRequest _unsignedRequest(Uri url, List<int> body) =>
      AWSHttpRequest.post(
        url,
        body: body,
        headers: {
          'content-type': 'application/json',
          'accept': 'application/json',
        },
      );
}
