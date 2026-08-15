# 工作区、项目与会话存储

本文说明 Vault 的产品模型（**工作区 → 项目 → 会话**）以及整套落盘机制。实现入口：

| 层 | 代码 |
|----|------|
| 工作区沙箱生命周期 | [`lib/sandbox/sandbox_provider.dart`](../lib/sandbox/sandbox_provider.dart)、`wsl_provider.dart`、`proot_provider.dart` |
| 工作区 bootstrap（目录 + git config） | [`lib/sandbox/workspace_bootstrap.dart`](../lib/sandbox/workspace_bootstrap.dart) |
| **主机元数据库（项目 + 会话）** | [`lib/agent/vault_meta_db.dart`](../lib/agent/vault_meta_db.dart) |
| 项目登记 / 时间戳目录 | [`lib/agent/project_store.dart`](../lib/agent/project_store.dart) |
| 会话 AgentState | [`lib/agent/conversation_store.dart`](../lib/agent/conversation_store.dart) |
| 会话分叉 / 截断 | [`lib/agent/conversation_state.dart`](../lib/agent/conversation_state.dart) |
| 项目文件检查点 | [`lib/agent/project_checkpoint.dart`](../lib/agent/project_checkpoint.dart) |
| 运行时接线 | [`lib/agent/agent_service.dart`](../lib/agent/agent_service.dart) |
| UI | [`home_screen.dart`](../lib/screens/home_screen.dart)、[`agent_screen.dart`](../lib/screens/agent_screen.dart)、[`new_project_dialog.dart`](../lib/widgets/new_project_dialog.dart) |

API Key / Base URL / 模型名存在 `flutter_secure_storage`，**从不**写入 SQLite。

---

## 1. 概念

```text
工作区 (Workspace)     1 : N     项目 (Project)     1 : N     会话 (Conversation)
├─ 独立 Alpine Linux            ├─ Linux 内时间戳目录            ├─ Agent 对话上下文
├─ 共享 /root 文件系统          ├─ 各自 git init                 ├─ 存在主机 SQLite
├─ 终端 / shell 工具            ├─ 元数据在主机 DB               └─ 按 workspace 分区
└─ 首页列表一行                 └─ 可选网址字典
```

| 术语 | 含义 | 标识符 |
|------|------|--------|
| **工作区** | 隔离 Linux（WSL2 / proot） | `workspaceId` |
| **项目** | 工程目录 + 元数据；会话挂其下 | `projectPath`（UTC `yyyyMMddHHmmss`） |
| **会话** | 项目内一条 Agent 对话 | `conversationId` |

**安全边界：** 项目登记与会话历史放在**主机侧**单一 SQLite（`vault_meta.db`），Agent 在 guest Linux 内**无法**用 shell 直接改库。Linux 里只有项目工作树（源码 / `.git`）。

---

## 2. 主机侧：`vault_meta.db`

| 平台 | 路径 |
|------|------|
| **Windows** | `{ApplicationSupport}/vault_meta.db` |
| **Android** | `{filesDir}/vault_meta.db` |

同文件内用 `workspace_id` 区分各工作区的项目与会话。

### Schema（要点）

| 表 | 作用 |
|----|------|
| `workspace_state` | 每工作区 `active_project_path` |
| `projects` | `(workspace_id, path)` PK；名称与时间戳 |
| `project_urls` | 网址字典；`sort_order` = 启动顺序 |
| `project_state` | 每项目 `active_conversation_id` |
| `conversations` | 会话元数据 + `state_json`（完整 AgentState）；可选 `parent_id` / `forked_from_message_index` / `head_tree_sha` |

沙箱清单仍为平台侧 `workspaces.json`（与元数据库分离）。

---

## 3. Linux 内部（仅工作树）

```text
/root/
├── inbox/
└── projects/
    └── {yyyyMMddHHmmss}/     # 项目目录 + .git（无 projects.db）
```

工作区初始化：`mkdir` 项目区 + 全局 `git config`（Vault / vault@local / main）。  
新建项目：时间戳目录 + `git init`；元数据写入主机 DB。

旧版 guest `/root/.vault/conversations/` 在 bootstrap 时迁入主机 DB（项目名「已迁移」）。

---

## 4. 运行时数据流

```text
HomeScreen
  ├─ VaultMetaDb.openDefault()
  ├─ list() ← workspaces.json
  ├─ ProjectStore / ConversationStore ← vault_meta.db
  └─ AgentScreen(…)

AgentScreen
  ├─ 无项目 → 弹窗「新建项目」
  ├─ 侧栏「站点」→ 一键启动已登记 URL（`ProjectSiteLauncher`）
  └─ AgentService.open(projectPath)
        ├─ ConversationStore → 主机 SQLite
        └─ tools: shell + register_project_url / list_project_urls
```

Agent 用 Python 做好本地网站后调用 `register_project_url` 写入 `project_urls`；用户下次打开可在侧栏看到并点击「启动」。

---

## 5. 删除语义

| 用户动作 | 效果 |
|----------|------|
| 删除会话 | 删主机 DB 对应行；至少保留一条空会话。子会话变成根（`parent_id` 置空），不级联删除。Linux 文件不删。 |
| 删除项目 | 删主机行 + guest 项目目录 |
| 删除工作区 | 销毁沙箱 + `VaultMetaDb.deleteWorkspace` |

切换或分叉会话会改工作树：先给当前会话打检查点，再恢复目标会话的 `head_tree_sha`。侧栏切换时显示「正在恢复项目文件…」。

---

## 5.1 会话分支与文件检查点

同一项目下的会话可以分叉：修改用户气泡或重选已完成的 `ask_user` 会保留旧会话，复制截断后的 `AgentState` 为子会话并立刻切过去。

工作树跟随**当前活动会话**的检查点，不再由全部会话共享同一份未版本化的目录状态：

- 检查点写在 guest git 的孤儿引用 `refs/vault/c/<conversationId>`（`git write-tree` / `commit-tree`），不切换用户当前 branch。
- 每个用户回合开始前、`ask_user` 出示时、回合成功结束后各打一次点；切换项目/会话时先保存当前树再恢复目标 `head_tree_sha`。
- SHA 记在 `conversations.head_tree_sha` 与 `AgentState.metadata['vaultCheckpoints']`。没有 SHA 的旧会话第一次切换只记录当前树，无法精确回到更早轮次。
- `.gitignore` 忽略的未跟踪文件不会进检查点；与 Agent 自己的 `git commit` 并存。

---

## 6. 相关测试

- [`test/project_store_test.dart`](../test/project_store_test.dart)
- [`test/conversation_store_test.dart`](../test/conversation_store_test.dart)
- [`test/agent_conversation_switch_test.dart`](../test/agent_conversation_switch_test.dart)
- [`test/project_checkpoint_test.dart`](../test/project_checkpoint_test.dart)
- [`test/ask_user_test.dart`](../test/ask_user_test.dart)
- [`test/agent_ui_history_mapper_test.dart`](../test/agent_ui_history_mapper_test.dart)
