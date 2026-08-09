# 工作区与会话存储

本文说明 Vault 的产品模型（**工作区 → 会话**）以及整套落盘机制。实现入口：

| 层 | 代码 |
|----|------|
| 工作区沙箱生命周期 | [`lib/sandbox/sandbox_provider.dart`](../lib/sandbox/sandbox_provider.dart)、`wsl_provider.dart`、`proot_provider.dart` |
| Guest 文件读写（无 PTY） | [`lib/sandbox/workspace_guest_fs.dart`](../lib/sandbox/workspace_guest_fs.dart) + Provider 上的 `read/write/deleteGuest*` |
| 会话目录与 AgentState | [`lib/agent/conversation_store.dart`](../lib/agent/conversation_store.dart) |
| 运行时接线 | [`lib/agent/agent_service.dart`](../lib/agent/agent_service.dart) |
| UI | [`lib/screens/home_screen.dart`](../lib/screens/home_screen.dart)、[`agent_screen.dart`](../lib/screens/agent_screen.dart) |

API Key / Base URL / 模型名存在 `flutter_secure_storage`，**从不**写入下文任何 JSON。

---

## 1. 概念

```text
工作区 (Workspace)          1 : N          会话 (Conversation)
├─ 一套独立 Alpine Linux                   ├─ 一轮 Agent 对话上下文
├─ 共享 /root 文件系统                     ├─ JSON 落在 Linux 内
├─ 终端 (PTY) 与 shell 工具                └─ 可新建 / 切换 / 删除
└─ 首页列表中的一行
```

| 术语 | 含义 | 标识符 |
|------|------|--------|
| **工作区** | 隔离的 Linux 执行环境（Windows = 一个 WSL2 发行版；Android = 一份 proot rootfs） | `workspaceId`（12 位 hex） |
| **会话** | 工作区内的一条 Agent 对话线程；互不影响模型上下文 | `conversationId`（12 位 hex） |

约定：

- **会话数据存在 Linux 内部**（guest 路径 `/root/.vault/conversations/`），与沙箱磁盘同生共死。
- 同工作区的多条会话共享 guest 文件系统与终端环境。
- 删除会话只删 `/root/.vault/conversations/` 下对应 JSON，不删用户其它 Linux 文件。
- 删除工作区会销毁整套沙箱（含全部会话 JSON）。
- 不兼容主机侧旧目录 `agent_states/` 或 `sessions.json`；需新建工作区。

引擎侧注意：`vault_agent_core` 的 `AgentState.sessionId` 在 Vault 里存放的是 **conversationId**；工作区 id 写在 `metadata['workspaceId']`。

---

## 2. 主机侧：沙箱元数据与磁盘

会话 JSON **不**单独放在 ApplicationSupport；主机只保留沙箱生命周期元数据与磁盘镜像。

| 平台 | 元数据 | 沙箱磁盘 |
|------|--------|----------|
| **Windows** | `{ApplicationSupport}/wsl_distros/workspaces.json` | `{ApplicationSupport}/wsl_distros/{workspaceId}/` + WSL 发行版 `vault_{workspaceId}` |
| **Android** | `{filesDir}/workspaces/workspaces.json` | `{filesDir}/workspaces/{workspaceId}/rootfs/` |

示意：

```text
主机
├── wsl_distros/ 或 workspaces/
│   ├── workspaces.json          # 仅工作区清单
│   └── {workspaceId}/           # vhdx / rootfs …
│
└── （Linux 内部，见下一节）
    /root/.vault/conversations/  # 会话 JSON
```

### `workspaces.json` schema

```json
{
  "workspaces": {
    "<workspaceId>": { /* 平台相关字段 */ }
  }
}
```

Windows 条目：`distro`、`path`、`createdAt`。  
Android 条目：`rootfs`、`createdAt`。

---

## 3. Linux 内部：会话存储

常量（[`sandbox_models.dart`](../lib/sandbox/sandbox_models.dart)）：

- `kGuestVaultDir` = `/root/.vault`
- `kGuestConversationsDir` = `/root/.vault/conversations`

### 3.1 布局

```text
/root/.vault/conversations/
  index.json                 # 会话目录 + activeConversationId
  {conversationId}.json      # 完整 AgentState
```

在 Android 上，该路径对应主机文件：

`{filesDir}/workspaces/{workspaceId}/rootfs/root/.vault/conversations/…`

在 Windows 上，文件在 WSL 发行版文件系统内（经 `\\wsl$\vault_{id}\…` 或 `wsl.exe` 读写）。

### 3.2 `index.json`

```json
{
  "activeConversationId": "c_abc12def345",
  "conversations": [
    {
      "id": "c_abc12def345",
      "title": "写个贪吃蛇",
      "createdAt": "2026-08-09T07:01:00.000Z",
      "updatedAt": "2026-08-09T07:05:00.000Z",
      "messageCount": 4
    }
  ]
}
```

| 字段 | 说明 |
|------|------|
| `activeConversationId` | 进入工作区时默认打开的会话 |
| `title` | 首条用户消息截断（约 24 字）；空会话为「新会话」 |
| `messageCount` | `AgentState.history.messages.length` |

### 3.3 `{conversationId}.json`

引擎 `AgentState.toJson()`：`sessionId`（= conversationId）、`metadata.workspaceId`、`history.messages` 等。加载时强制 `isRunning = false`。

### 3.4 访问方式（`SandboxProvider`）

无需打开交互 PTY：

| 方法 | 作用 |
|------|------|
| `readGuestFile(workspaceId, path)` | 读字节；不存在返回 null |
| `writeGuestFile(workspaceId, path, bytes)` | 写字节（自动 `mkdir -p`） |
| `deleteGuestPath(workspaceId, path, {recursive})` | 删文件或目录 |

实现：

- **Windows**：优先 `\\wsl$\vault_{id}\…` UNC；失败则 `wsl.exe` + base64 / `rm`。
- **Android**：映射到 `rootfs` 下对应主机路径。

[`ConversationStore`](../lib/agent/conversation_store.dart) 通过 [`WorkspaceGuestFs`](../lib/sandbox/workspace_guest_fs.dart)（生产用 `SandboxWorkspaceGuestFs`）读写上述路径。

---

## 4. 运行时数据流

```text
HomeScreen
  ├─ list() ← workspaces.json
  ├─ peekWorkspaceSummary() ← 读 guest index.json
  └─ create/attach → AgentScreen(workspace, conversationStore)

AgentScreen
  └─ AgentService.open
        ├─ ConversationStore.ensureActive → guest /root/.vault/conversations
        ├─ hydrate 聊天气泡
        └─ StatefulAgent.autoSaveStateFunc → 写回 guest JSON
```

删除工作区：`provider.destroy` 销毁整套 Linux（会话一并消失）；`ConversationStore.deleteWorkspace` 在 destroy 前尝试 `rm -rf` 会话目录（已销毁则忽略）。

---

## 5. ID 对照

| 名字 | 用途 |
|------|------|
| `workspaceId` | 沙箱 meta key、发行版/rootfs 名、`metadata['workspaceId']` |
| `conversationId` | guest 下 JSON 文件名、`index` 条目 id |
| `AgentState.sessionId` | **等于 conversationId**（引擎字段名） |

---

## 6. 删除语义

| 用户动作 | 效果 |
|----------|------|
| 删除会话 | 删 guest 下对应 JSON；至少保留一条空会话 |
| 删除工作区 | 注销 WSL / 删 rootfs + meta；会话随之消失 |
| 杀进程 / 离开页面 | 沙箱与已 autoSave 的会话保留 |

尚未做：启动自动打开上次工作区、磁盘占用汇总（见 [`feat.md`](./feat.md) F5 剩余项）。

---

## 7. 密钥

| 数据 | 位置 |
|------|------|
| API Base / Key / Model | `flutter_secure_storage` |
| 会话历史 | **Linux** `/root/.vault/conversations/` |
| 工作区清单 | 主机 `workspaces.json` |

---

## 8. 相关测试

- [`test/conversation_store_test.dart`](../test/conversation_store_test.dart) — 用 `LocalDirWorkspaceGuestFs` 模拟 guest 布局
- [`test/agent_conversation_switch_test.dart`](../test/agent_conversation_switch_test.dart)
- [`test/agent_ui_history_mapper_test.dart`](../test/agent_ui_history_mapper_test.dart)
