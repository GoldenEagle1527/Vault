typedef RetryDelay = Future<void> Function(Duration duration);
typedef BeforeRetry =
    void Function(int delayMs, int retryNumber, int maxRetries);

/// Per-request exponential retry state shared by provider clients.
///
/// The request loop remains provider-owned so response parsing, terminal error
/// behavior, and provider-specific retry reasons do not get conflated.
class RetryBackoff {
  final int maxRetries;
  final int initialDelayMs;
  final int maxDelayMs;
  final RetryDelay _delay;

  int _retryCount = 0;
  late int _nextDelayMs = initialDelayMs;

  RetryBackoff({
    required this.maxRetries,
    required this.initialDelayMs,
    required this.maxDelayMs,
    RetryDelay? delay,
  }) : _delay = delay ?? Future<void>.delayed;

  int get retryCount => _retryCount;

  bool get canRetry => _retryCount < maxRetries;

  Future<void> wait(BeforeRetry beforeRetry) async {
    beforeRetry(_nextDelayMs, _retryCount + 1, maxRetries);
    await _delay(Duration(milliseconds: _nextDelayMs));
    _retryCount++;
    _nextDelayMs *= 2;
    if (_nextDelayMs > maxDelayMs) _nextDelayMs = maxDelayMs;
  }
}

bool isRetryableHttpStatus(int? statusCode) =>
    statusCode == 429 || (statusCode != null && statusCode >= 500);
