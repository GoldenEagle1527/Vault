/// Tool name used by vault_agent_core to launch a worker agent.
const String kDelegateTaskToolName = 'delegate_task';

bool isSubAgentTool(String? name) => name == kDelegateTaskToolName;

/// Capsule label above the transcript while worker agents run in the background.
String subAgentBackgroundCapsuleLabel(int count) =>
    '$count个子Agent后台运行中...';

/// In-conversation summary for a [delegate_task] tool row.
const String kStartSubAgentSummary = '启动子Agent';
