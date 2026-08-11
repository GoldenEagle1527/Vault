# Vault 未完成特性 / 跨会话 backlog

**用途：** 新开工前先读本文 + `README.md` + [`workspace-and-conversation-storage.md`](./workspace-and-conversation-storage.md)，避免重复做已验收项或重开已定决策。  
**更新约定：** 完成一项就勾掉并写日期；新增缺口直接补条目。不要把本文当「愿景文档」——只记**还没做完**的事。

**基线（已验收，勿重做）：**

| 层 | 状态 | 报告 |
|----|------|------|
| Windows 沙箱 MVP（WSL2 每会话一发行版 + 终端） | ✅ 2026-08-08 | [`windows-mvp-report.md`](./windows-mvp-report.md) |
| Android 沙箱 MVP（proot + 独立 rootfs + FGS + 终端） | ✅ 2026-08-08 | [`android-mvp-report.md`](./android-mvp-report.md) |
| GPLv3 + 侧载、不上 Play | ✅ | `LICENSE` / `THIRD_PARTY_LICENSES.md` |

**已定约束（勿再问）：**

- Android = jniLibs `libproot.so` + `PROOT_LOADER`，**禁止** assets + chmod + 直接 exec  
- 每工作区独立 rootfs（Android）/ 独立 WSL 发行版（Windows）  
- UI 语言 = 中文  
- 抽象见 `lib/sandbox/sandbox_provider.dart` —— **禁止**把 `dart:io Process` 泄漏进接口  

---

## 优先级总览

| ID | 项 | 优先级 | 状态 |
|----|----|--------|------|
| F1 | M4 Agent 编排层 | P0 | ✅ 2026-08-08（引擎=自有 `packages/vault_agent_core`） |
| F2 | 文件浏览器（会话内） | P0（可跟 F1 一起） | ✅ 2026-08-10 |
| F3 | Android M2c 设备矩阵补全 | P1 | 部分（仅一档真机） |
| F4 | 沙箱层自动化测试 | P1 | 偏薄 |
| F5 | 工作区/会话持久化增强 | P2 | ✅ 多会话历史 2026-08-09；启动续开/磁盘清理仍缺 |
| F6 | Differencing VHD（Windows 磁盘） | P3 / 延后 | 明确不做于 MVP |
| F7 | Docker 后端 / 桌面 Linux / iOS | 不做（当前） | 计划外 |
| F8 | Native Offload + API 权限组 | P1 | Wave0–4 已落地（Wave4=Android a11y/shizuku 骨架，默认 NOT_ALLOWED） |

---

## F1 — M4 Agent 编排层（P0）

**状态：** ✅ 2026-08-08 已落地（报告：[`agent-mvp-report.md`](./agent-mvp-report.md)）。

**目标：** 在已有 `SandboxSession.run` / 交互终端之上，做出「带工具的 Agent 会话」，而不是再造一层沙箱。

**引擎：** 自有模块 [`packages/vault_agent_core/`](../packages/vault_agent_core/)（vendored fork of [memex-lab/dart_agent_core](https://github.com/memex-lab/dart_agent_core)，见 `UPSTREAM.md`）。**禁止**从 pub.dev 安装 `dart_agent_core`。

**交付物：**

```
packages/vault_agent_core/   # 自有 Agent 编排引擎（非 pub 包）
lib/agent/
  agent_service.dart         # 对接 OpenAIClient / StatefulAgent，run/cancel/stream
  agent_settings.dart        # API base / key / model（flutter_secure_storage）
  agent_system_prompt.dart   # 绑定「一会话一 Alpine」与 /root/inbox
  agent_inbox.dart           # 用户附件写入 guest /root/inbox
  tools/shell_tool.dart      # Tool → SandboxSession.run（cwd=/root）
lib/screens/
  agent_screen.dart          # 对话 UI（中文）+ 附件
  settings_screen.dart       # 配置 API
```


**验收标准：**

1. 用户配置 API Key + model 后，可对某沙箱会话发起 Agent 任务  
2. Agent 至少能：在会话内执行 shell、读回 stdout/stderr/exitCode、多轮直到结束或用户取消  
3. 长任务期间：Android 仍依赖已有 FGS；不要再发明第二套保活  
4. 失败时有清晰中文错误（网络、401、沙箱不可用、命令超时）

**不要做：**

- 不要为 Agent 再开一套「共享 rootfs」  
- 不要在未完成 F3 风险说明前宣称「全 Android 版本已验证」  
- 不要把密钥写进仓库或 `workspaces.json`  
- 不要把 Agent 做成独立 OS 进程 / HTTP 微服务  

**依赖接口（已有）：**

- `SandboxProvider.create / attach / destroy / list / probe`  
- `SandboxSession.run(String cmd)`、`output` / `write` / `resize`（终端仍可并行打开）  
- Android：`ProotProvider.runOnce` 可作无 PTY 的 one-shot，但长期应以 `SandboxSession.run` 为准  

---

## F2 — 会话内文件浏览器（P0）

**状态：** ✅ 2026-08-10 已落地。

**目标：** 浏览 / 预览 /（可选）编辑当前会话 rootfs 或工作目录下的文件，服务 Agent 与人工排查。

**交付：**

- `SandboxProvider.listGuestDirectory` + `GuestFsEntry`（WSL UNC / proot host 列表，WSL 可 fallback `ls`）
- [`lib/screens/file_browser_screen.dart`](../lib/screens/file_browser_screen.dart) — 列表、面包屑、文本高亮预览/保存、图片/音视频预览
- 入口：工作区 [`AgentScreen`](../lib/screens/agent_screen.dart) → 工具 →「文件浏览器」（销毁/离开工作区后入口消失）

**验收：** 在已存在工作区上打开文件树，能打开 `/root` 下文本文件，删除工作区后入口消失。

---

## F3 — Android M2c 设备矩阵补全（P1）

**现状：** [`android-m2-matrix.md`](./android-m2-matrix.md) 仅「至少一档真机」通过；计划要求多版本 + 页大小。

**待补档：**

- [ ] Android 10  
- [ ] Android 12  
- [ ] Android 14  
- [ ] Android 15 QPR2  
- [ ] Android 16  
- [ ] 4KB 页设备至少一档  
- [ ] 16KB 页设备至少一档  

**每档最少记录：** 型号、Android 版本、`getconf PAGE_SIZE`、`uname -a`、`apk update` 成败、备注。  
**完成后：** 更新 `android-m2-matrix.md` 与本表勾选。

---

## F4 — 沙箱层自动化测试（P1）

**现状：** 仅有 `test/wsl_output_test.dart`、默认 widget smoke；`WslProvider` / `ProotProvider` 几乎无单测。

**建议补：**

| 测试 | 说明 |
|------|------|
| `rootfs_extract` 单测 | 绝对 symlink → 相对；执行位保留；缺 `/bin/sh` 应失败 |
| `wsl_output` 解码 | 已有，保持回归 |
| Provider 契约（可 mock） | workspaceId 校验、meta 读写、destroy 清理 meta |
| （可选）集成 | Windows 本机有 WSL 时跳过/启用；Android 以仪表测试或文档化手工脚本为准 |

---

## F5 — 工作区 / 会话持久化增强（P2）

**已有：** `workspaces.json`（Windows / Android 各一份工作区元数据）。  

**已完成（2026-08-09）：**

- 用户可见「任务」→「工作区」
- 工作区内多会话：`agent_states/{workspaceId}/index.json` + `{conversationId}.json`
- 重开工作区恢复会话列表与对话气泡 / Agent 上下文；删除工作区级联清理会话目录

**未有：**

- 跨重启自动打开「上次工作区」  
- 磁盘占用汇总与一键清理策略（UI 已有单工作区删除，可加强提示）

---

## F6 — Windows Differencing VHD（P3 / 延后）

**动机：** 每会话 `ext4.vhdx` 常近 ~1 GB；差分盘可显著降磁盘。  
**代价：** `New-VHD` + 手写 `HKCU\...\Lxss`、通常需管理员 —— MVP 明确推迟。  
**触发条件：** 用户强烈反馈磁盘占用，且不愿用「少开会话」规避时再开。

---

## F7 — 明确不做（当前阶段）

- Play 上架 / 规避 Play「下载并执行代码」政策  
- Docker Desktop 作为 Windows 会话后端  
- iOS / macOS / 桌面 Linux 沙箱  
- 依赖 `workspace_sandbox` 包作为跨平台基础  
- 自研完整 proot 补丁树（继续 vendor oonid/pr 预编译或同源构建）

---

## F8 — Native Offload + API 权限组（P1）

**状态：** Wave0–4 已落地（Wave4 为 Android `a11y` / `shizuku` 骨架：status/smoke，默认 NOT_ALLOWED；无完整 UI 自动化 / Shizuku binder）。规格：[`vault-permission-api.md`](./vault-permission-api.md)。

**目标：** 让 guest 内 Agent / 用户通过统一的 `vault-*` CLI 调用宿主能力（剪贴板、日历、通知、TTS 等），并由 Dart 侧权限注册表按组管控（`BYPASS` / `ASK_ONCE` / `NOT_ALLOWED`），而不是把敏感 API 直接敞给 shell。

**范围平台：** Android + Windows bridges。**不做 iOS。**

**权限组：** `privacy` · `host` · `media` · `system` · `integrations` · `config`

**注册表要点（详见规格文档）：**

| 能力 | Guest CLI | 组 | 默认 |
|------|-----------|----|------|
| clipboard / calendar / contacts / photos | `vault-*` | privacy | BYPASS（location = ASK_ONCE） |
| host_files | `vault-host-files` | host | ASK_ONCE |
| notification / device / open / weather | `vault-*` | system | BYPASS（alarm：Windows 延后） |
| speak / speech / player | `vault-*` | media | BYPASS（player：Windows 延后） |
| a11y / shizuku | `vault-*` | integrations | NOT_ALLOWED（仅 Android） |
| vault_config | `vault-config` | config | 总开关默认开；允许写 provider/API key/model，禁止读回密钥 |

**交付方向：**

1. Guest 侧薄 CLI（`vault-clipboard` 等）→ 经 bridge 调宿主；拒绝时 exit `126`（`permission_denied`），平台不支持 exit `125`（`unsupported_platform`）  
2. Dart 权限注册表 + 会话绑定（`VAULT_CHAT_SESSION_ID`）  
3. 设置页权限组 IA + **「一键统测」** smoke（对当前会话批量跑 CLI）  
4. 分波落地（与规格对齐）：

| Wave | 范围 | 状态 |
|------|------|------|
| **0** | 桥 + 权限核 + Settings壳 + 一键统测框架；协议 125/126；`VAULT_CHAT_SESSION_ID` | 已落地 |
| **1** | `clipboard`、`device_info`（`vault-device`）、`open_url`（`vault-open`）、`notification` | 已落地 |
| **2** | `calendar`、`contacts`、`photos`、`location` | 已落地 |
| **3** | `host_files`、`vault_config`、`speak`、`speech`；（`player`/`alarm` 按平台） | 已落地（host_files / vault_config / speak / speech） |
| **4** | Android `a11y`、`shizuku`（可选）；统测扩表 | 骨架已落地（status/smoke；默认 NOT_ALLOWED） |

**不要做：** 见 [`vault-permission-api.md`](./vault-permission-api.md) Non-goals；尤其不要做 iOS、不要把 OS 权限弹窗逻辑塞进 guest、不要另起一套与注册表无关的 ad-hoc MethodChannel。

---

## 新开工清单

1. 读本文 + [`README.md`](../README.md) + [`workspace-and-conversation-storage.md`](./workspace-and-conversation-storage.md)  
2. 若动沙箱：读对应 MVP 报告与 `lib/sandbox/*`（`SandboxWorkspace` / `workspaceId`）  
3. 若做 Agent：复用 `SandboxWorkspace` + `ConversationStore`，shell 只打当前工作区  
4. 改 Android 原生 / proot：同步看 [`android-mvp-report.md`](./android-mvp-report.md) §5 踩坑  

**完成 F1/F2 后：** 在本文勾选，并补一份 `docs/agent-mvp-report.md`（建议），把验收命令与密钥存储方案写死。
