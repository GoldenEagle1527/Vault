import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_service.dart';

void main() {
  test('isVisibleAssistantText rejects blank model deltas', () {
    expect(AgentService.isVisibleAssistantText(null), isFalse);
    expect(AgentService.isVisibleAssistantText(''), isFalse);
    expect(AgentService.isVisibleAssistantText('   '), isFalse);
    expect(AgentService.isVisibleAssistantText('\n'), isFalse);
    expect(AgentService.isVisibleAssistantText('\n  \t'), isFalse);
    expect(AgentService.isVisibleAssistantText('好的'), isTrue);
  });
}
