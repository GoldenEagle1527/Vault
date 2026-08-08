import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_service.dart';

void main() {
  test('normalizeBaseUrl keeps /v1 for OpenAI-compatible gateways', () {
    expect(
      AgentService.normalizeBaseUrlForTest('https://apihub.agnes-ai.com/v1'),
      'https://apihub.agnes-ai.com/v1',
    );
    expect(
      AgentService.normalizeBaseUrlForTest('https://apihub.agnes-ai.com/v1/'),
      'https://apihub.agnes-ai.com/v1',
    );
    expect(
      AgentService.normalizeBaseUrlForTest('https://apihub.agnes-ai.com'),
      'https://apihub.agnes-ai.com/v1',
    );
    expect(
      AgentService.normalizeBaseUrlForTest(
        'https://apihub.agnes-ai.com/v1/chat/completions',
      ),
      'https://apihub.agnes-ai.com/v1',
    );
  });
}
