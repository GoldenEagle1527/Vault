import 'dart:convert';

import 'package:vault_agent_core/vault_agent_core.dart';

const kVaultCheckpointsMeta = 'vaultCheckpoints';
const kHeadTreeShaMeta = 'headTreeSha';

const kCheckpointUserTurn = 'user_turn';
const kCheckpointAskUser = 'ask_user';
const kCheckpointTurnEnd = 'turn_end';

class VaultCheckpoint {
  const VaultCheckpoint({
    required this.index,
    required this.sha,
    required this.kind,
  });

  final int index;
  final String sha;
  final String kind;

  Map<String, dynamic> toJson() => {'index': index, 'sha': sha, 'kind': kind};

  factory VaultCheckpoint.fromJson(Map<String, dynamic> json) {
    return VaultCheckpoint(
      index: (json['index'] as num?)?.toInt() ?? 0,
      sha: json['sha'] as String? ?? '',
      kind: json['kind'] as String? ?? kCheckpointTurnEnd,
    );
  }
}

AgentState cloneAgentState(AgentState source) {
  final raw = jsonDecode(jsonEncode(source.toJson()));
  final map = raw is Map<String, dynamic>
      ? raw
      : (raw as Map).cast<String, dynamic>();
  return AgentState.fromJson(map);
}

/// Keep the first [keepCount] history messages and drop later engine snapshots.
AgentState truncateAgentState(AgentState source, int keepCount) {
  final state = cloneAgentState(source);
  final n = keepCount < 0 ? 0 : keepCount;
  if (state.history.messages.length > n) {
    state.history.messages = state.history.messages.sublist(0, n);
  }
  state.systemPromptHistory = [
    for (final item in state.systemPromptHistory)
      if (item.validFromMessageIndex < n) item,
  ];
  state.toolsHistory = [
    for (final item in state.toolsHistory)
      if (item.validFromMessageIndex < n) item,
  ];
  state.plan = null;
  state.metadata[kVaultCheckpointsMeta] = [
    for (final c in readCheckpoints(state))
      if (c.index < n) c.toJson(),
  ];
  return state;
}

List<VaultCheckpoint> readCheckpoints(AgentState state) {
  final raw = state.metadata[kVaultCheckpointsMeta];
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map) VaultCheckpoint.fromJson(item.cast<String, dynamic>()),
  ];
}

void recordCheckpoint(
  AgentState state, {
  required int index,
  required String sha,
  required String kind,
}) {
  final next = [
    ...readCheckpoints(
      state,
    ).where((c) => !(c.index == index && c.kind == kind)),
    VaultCheckpoint(index: index, sha: sha, kind: kind),
  ];
  state.metadata[kVaultCheckpointsMeta] = [for (final c in next) c.toJson()];
  if (kind == kCheckpointTurnEnd) {
    state.metadata[kHeadTreeShaMeta] = sha;
  }
}

String? checkpointShaAt(AgentState state, int index, {String? kind}) {
  final all = readCheckpoints(state);
  if (kind != null) {
    for (var i = all.length - 1; i >= 0; i--) {
      final c = all[i];
      if (c.kind == kind && c.index == index && c.sha.isNotEmpty) return c.sha;
    }
  }
  VaultCheckpoint? best;
  for (final c in all) {
    if (c.sha.isEmpty || c.index > index) continue;
    if (best == null || c.index > best.index) best = c;
  }
  return best?.sha;
}

String? headTreeShaOf(AgentState state) {
  final raw = state.metadata[kHeadTreeShaMeta];
  if (raw is String && raw.isNotEmpty) return raw;
  final all = readCheckpoints(state);
  for (var i = all.length - 1; i >= 0; i--) {
    if (all[i].sha.isNotEmpty) return all[i].sha;
  }
  return null;
}

/// Visible user words from a stored model-facing user prompt.
String displayTextFromStoredUserPrompt(String stored) {
  var text = stored.trim();
  while (true) {
    final start = text.indexOf('[Vault');
    if (start < 0) break;
    final end = text.indexOf(']', start);
    if (end < 0) {
      text = text
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('[Vault'))
          .join('\n')
          .trim();
      break;
    }
    text = (text.substring(0, start) + text.substring(end + 1)).trim();
  }
  return text.replaceAll(RegExp(r'\n\[附件 \d+ 个\]\s*$'), '').trim();
}
