import 'package:test/test.dart';
import 'package:vault_agent_core/src/llm/retry_backoff.dart';

void main() {
  test('keeps retry count and capped exponential delays per request', () async {
    final delayed = <Duration>[];
    final announced = <(int, int, int)>[];
    final retry = RetryBackoff(
      maxRetries: 3,
      initialDelayMs: 10,
      maxDelayMs: 15,
      delay: (duration) async => delayed.add(duration),
    );

    expect(retry.retryCount, 0);
    expect(retry.canRetry, isTrue);

    while (retry.canRetry) {
      await retry.wait((delayMs, retryNumber, maxRetries) {
        announced.add((delayMs, retryNumber, maxRetries));
      });
    }

    expect(delayed, [
      const Duration(milliseconds: 10),
      const Duration(milliseconds: 15),
      const Duration(milliseconds: 15),
    ]);
    expect(announced, [(10, 1, 3), (15, 2, 3), (15, 3, 3)]);
    expect(retry.retryCount, 3);
    expect(retry.canRetry, isFalse);
  });

  test('retries only throttling and server statuses', () {
    expect(isRetryableHttpStatus(null), isFalse);
    expect(isRetryableHttpStatus(408), isFalse);
    expect(isRetryableHttpStatus(429), isTrue);
    expect(isRetryableHttpStatus(499), isFalse);
    expect(isRetryableHttpStatus(500), isTrue);
    expect(isRetryableHttpStatus(503), isTrue);
  });
}
