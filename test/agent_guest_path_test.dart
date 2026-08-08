import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_system_prompt.dart';
import 'package:vault/sandbox/sandbox_models.dart';

void main() {
  test('assertGuestPathUnderHome rejects escape', () {
    expect(() => assertGuestPathUnderHome('/etc/passwd'), throwsArgumentError);
    expect(
      () => assertGuestPathUnderHome('/root/../etc/passwd'),
      throwsArgumentError,
    );
    expect(assertGuestPathUnderHome('/root/inbox/a.txt'), '/root/inbox/a.txt');
    expect(assertGuestPathUnderHome('/root/./work/x'), '/root/work/x');
  });

  test('sanitizeInboxFileName strips directories', () {
    expect(sanitizeInboxFileName(r'C:\Users\a\b.txt'), 'b.txt');
    expect(sanitizeInboxFileName('../../x.sh'), 'x.sh');
    expect(inboxGuestPath('note.md'), '/root/inbox/note.md');
  });

  test('system prompt pins Alpine session + inbox', () {
    final prompts = vaultAgentSystemPrompts(sessionId: 'abc123');
    final joined = prompts.join('\n');
    expect(joined, contains('sessionId=abc123'));
    expect(joined, contains('Alpine'));
    expect(joined, contains('/root/inbox'));
    expect(joined, contains('不是用户的 Windows/Android 主机'));
  });

  test('attachment context lists guest paths', () {
    final msg = buildAttachmentContextMessage([
      '/root/inbox/a.pdf',
      '/root/inbox/b.txt',
    ]);
    expect(msg, contains('/root/inbox/a.pdf'));
    expect(msg, contains('/root/inbox/b.txt'));
  });
}
