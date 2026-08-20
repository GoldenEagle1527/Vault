import 'package:flutter_test/flutter_test.dart';
import 'package:vault/agent/agent_service.dart';
import 'package:vault/agent/agent_system_prompt.dart';
import 'package:vault/agent/vault_host_device.dart';
import 'package:vault/agent/workspace_mode.dart';
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

  test('sanitizeInboxFileName keeps CJK and strips illegal chars', () {
    expect(sanitizeInboxFileName('重金属厚涂风格敏捷机甲头颅设计.png'), '重金属厚涂风格敏捷机甲头颅设计.png');
    expect(sanitizeInboxFileName('a:b?.png'), 'a_b_.png');
    expect(sanitizeInboxFileName('foo/bar.png'), 'bar.png');
  });

  test('project inbox helpers stay under the project', () {
    expect(guestProjectInboxDir('p1'), '/root/projects/p1/inbox');
    expect(
      projectInboxGuestPath('p1', 'a.png'),
      '/root/projects/p1/inbox/a.png',
    );
    expect(allocateInboxFileName('a.png', {'a.png'}), 'a-2.png');
    expect(allocateInboxFileName('a.png', {'a.png', 'a-2.png'}), 'a-3.png');
  });

  test('system prompt pins Alpine workspace + inbox', () {
    final prompts = vaultAgentSystemPrompts(
      workspaceId: 'abc123',
      hostDevice: VaultHostDevice.desktop,
    );
    final joined = prompts.join('\n');
    expect(joined, contains('workspaceId=abc123'));
    expect(joined, contains('Alpine'));
    expect(joined, contains('/root/inbox'));
    expect(joined, contains('不是用户的 Windows 主机'));
    expect(joined, contains('用户当前在 **电脑**'));
    expect(joined, contains('Python 3.12'));
    expect(joined, contains('python3'));
    expect(joined, contains('read（读文本或图片'));
  });

  test('system prompt includes mobile host device', () {
    final joined = vaultAgentSystemPrompts(
      workspaceId: 'abc123',
      hostDevice: VaultHostDevice.mobile,
    ).join('\n');
    expect(joined, contains('用户当前在 **手机**'));
    expect(joined, contains('Android'));
    expect(joined, contains('proot'));
    expect(joined, contains('触屏'));
    expect(joined, contains('不是用户的 Android 主机'));
  });

  test('system prompt with project uses project inbox', () {
    final joined = vaultAgentSystemPrompts(
      workspaceId: 'abc123',
      projectPath: '20260101',
    ).join('\n');
    expect(joined, contains('/root/projects/20260101/inbox'));
    expect(
      joined,
      isNot(contains('用户通过 App 附带的文件会写入当前项目的 inbox/（/root/inbox）')),
    );
  });

  test('attachment context lists guest paths', () {
    final msg = buildAttachmentContextMessage([
      '/root/inbox/a.pdf',
      '/root/inbox/b.txt',
    ]);
    expect(msg, contains('/root/inbox/a.pdf'));
    expect(msg, contains('/root/inbox/b.txt'));
  });

  test('dev prompt mentions inspect_site; chat prompt does not', () {
    final dev = vaultAgentSystemPrompts(
      workspaceId: 'abc123',
      mode: WorkspaceMode.dev,
    ).join('\n');
    expect(dev, contains('inspect_site'));
    expect(dev, contains('不要让用户去开 F12'));

    final chat = vaultAgentSystemPrompts(
      workspaceId: 'abc123',
      mode: WorkspaceMode.chat,
    ).join('\n');
    expect(chat, isNot(contains('inspect_site')));
  });

  test('user turn prompt is the original text, not auto-attached errors', () {
    const userText = '不能用';
    expect(AgentService.userTurnDisplayText(userText), userText);
    expect(composeModelUserPrompt(userText: userText), userText);
  });
}
