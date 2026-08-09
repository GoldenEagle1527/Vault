# Vault Agent 接入 MVP 报告

**状态：** 已落地（Windows 联调通过路径层；Android 共用同一 Agent 代码，长任务仍依赖既有 FGS）  
**日期：** 2026-08-08  
**依赖基线：** Windows / Android 沙箱 MVP 已验收  
**许可：** GPLv3（应用）；编排引擎 fork 为 MIT（Memex Lab，见 `THIRD_PARTY_LICENSES.md`）

---

## 1. 目标与范围

在已有「一会话一隔离 Alpine Linux」之上，接入 **BYO OpenAI 兼容 API** 的 Agent 编排：模型通过 **shell 工具** 只在该会话 guest 内操作，并可把用户附件注入 guest。

| 能力 | MVP 结果 |
|------|----------|
| 自有编排引擎（非 pub.dev 包） | ✅ `packages/vault_agent_core` |
| OpenAI 兼容客户端 + 自定义 base/key/model | ✅ 安全存储密钥 |
| 多轮 tool loop：shell → stdout/stderr/exitCode | ✅ |
| 系统提示绑定「本会话 Alpine / `/root` / inbox」 | ✅ |
| 用户附件写入 guest `/root/inbox/` | ✅ |
| 取消进行中的 Agent 任务 | ✅ |
| 中文 UI + 中文错误（含 Cloudflare/错误 URL） | ✅ |
| Base URL 保留 `/v1`（兼容网关） | ✅ |
| 独立 OS 进程 / HTTP Agent 微服务 | ❌ 明确不做 |
| 子 Agent / Skills / 本地 LLM | ❌ 本阶段不做 |
| 会话内文件浏览器（F2） | ❌ 未做 |

---

## 2. 交付物

```
packages/vault_agent_core/     # vendored fork of memex-lab/dart_agent_core
  UPSTREAM.md                  # 上游 URL、commit、维护约定
  lib/vault_agent_core.dart
lib/agent/
  agent_service.dart           # StatefulAgent 适配、流式事件、取消、错误映射
  agent_settings.dart          # API base / key / model（flutter_secure_storage）
  agent_system_prompt.dart     # 会话绑定系统提示
  agent_inbox.dart             # 附件注入 /root/inbox
  tools/shell_tool.dart        # Tool → SandboxSession.run
lib/screens/
  agent_screen.dart            # 对话 + 附件 + 取消
  settings_screen.dart         # API 配置
lib/sandbox/
  sandbox_models.dart          # + writeGuestFile / inbox 路径工具
  wsl_provider.dart            # run --cd /root；UNC/base64 写文件
  proot_provider.dart          # rootfs 直写 guest 文件
test/
  agent_shell_tool_test.dart
  agent_guest_path_test.dart
  agent_base_url_test.dart
docs/agent-mvp-report.md       # 本文
docs/feat.md                   # F1 勾选
```

**根依赖（摘录）：**

- `vault_agent_core: path: packages/vault_agent_core`（**禁止** `dart_agent_core` from pub.dev）
- `flutter_secure_storage`、`file_picker`、`dio`

---

## 3. 架构

```
Agent 设置（安全存储）
        │
        ▼
agent_screen ──附件──► writeGuestFile → /root/inbox/*
        │
        ▼
agent_service + vault_agent_core (StatefulAgent)
        │  OpenAI-compatible HTTP  …/v1/chat/completions
        │
        ▼
shell tool → SandboxSession.run (cwd=/root)
        │
   ┌────┴────┐
   ▼         ▼
WslSession  ProotSession
(WSL2)      (Android proot)
```

要点：

- Agent **进程内**运行，与 Flutter UI 同进程；不另起微服务。
- 工具执行面只有 guest shell；主机路径对模型不可见（附件先注入再给 guest 路径）。
- Android 长任务：**不新增**保活，继续用沙箱层既有 Foreground Service。

---

## 4. 使用说明

1. 首页右上角 **Agent 设置**：填写  
   - Base URL（须含 `/v1`，如 `https://api.openai.com/v1` 或兼容网关 `https://apihub.example.com/v1`）  
   - API Key  
   - 模型名  
2. 已有会话行点击 **Agent**（或终端旁机器人图标）。  
3. 可选：回形针附加文件 → 发送前写入该会话 `/root/inbox/`。  
4. 输入任务；Agent 通过 shell 在 Alpine 内执行；可用停止按钮取消。

```bash
flutter pub get
flutter run -d windows
# 或 Android 侧载调试包（沙箱 + Agent 同 APK）
```

---

## 5. 验收记录

| # | 标准 | 结果 |
|---|------|------|
| 1 | 配置 Key/model 后可对会话发起任务 | ✅ UI + 设置链路 |
| 2 | shell 多轮、读回 exitCode/stdout/stderr，可取消 | ✅ `shell_tool` + `CancelToken` |
| 3 | Android 不新增第二套保活 | ✅ 无新 FGS |
| 4 | 网络/401/沙箱/超时等中文错误 | ✅；Cloudflare HTML 已压缩提示 |
| 5 | Base URL `/v1` 不被剥掉 | ✅ 单测 + 网关探测（错误路径 403 CF，正确路径到业务 API） |
| 6 | 附件进入 guest inbox | ✅ `writeGuestFile` + 上下文注入 |
| 7 | 单元测试 | ✅ `agent_*_test.dart` |
| 8 | Windows debug 构建 | ✅ `flutter build windows --debug` |

**已知联调注意：**

- 部分兼容网关（Cloudflare 后）若请求打到 **无 `/v1`** 的路径，会返回整页 403 HTML，而非 JSON；设置里务必带 `/v1`。
- 勿把 API Key 写入仓库或 `sessions.json`；勿在聊天/截图中泄露 Key。

---

## 6. 关键决策

| 决策 | 说明 |
|------|------|
| 收编而非 pub 依赖 | fork 到 `packages/vault_agent_core`，改名维护，避免上游发版牵制 |
| 进程内适配 | `lib/agent/*` 薄封装；循环由 `StatefulAgent` 负责 |
| 仅暴露 OpenAI 兼容 | fork 内 Gemini/Claude 等保留，UI 不暴露 |
| guest 写文件进抽象 | `SandboxSession.writeGuestFile`，禁止把 `Process` 泄漏到 UI |
| inbox 约定 | 固定 `/root/inbox/`，文件名 sanitize，禁止逃出 `/root` |

上游钉死：`packages/vault_agent_core/UPSTREAM.md` → commit `683d942ea175c4a5be6cd52c609f4116a48c9b3c`。

---

## 7. 后续（非本 MVP）

- F2 会话内文件浏览器（与 inbox / Agent 工具共用）
- ~~Agent 对话历史持久化（F5）~~ → 已做：工作区多会话（见 `docs/feat.md` F5）；启动自动续开工作区 / 磁盘清理仍缺
- 按需裁剪 fork（eval / sub-agent）以减小体积
- Android 多档设备上的 Agent 长任务抽检（依赖 F3 矩阵）

---

## 8. 参考

- [`docs/feat.md`](./feat.md) — F1 条目  
- [`docs/windows-mvp-report.md`](./windows-mvp-report.md) / [`docs/android-mvp-report.md`](./android-mvp-report.md) — 沙箱基线  
- [`packages/vault_agent_core/UPSTREAM.md`](../packages/vault_agent_core/UPSTREAM.md)  
- [memex-lab/dart_agent_core](https://github.com/memex-lab/dart_agent_core)
