# Vault Permission API — Native Offload 注册表规格

**特性 ID：** F8（见 [`feat.md`](./feat.md)）  
**平台：** Android + Windows（**不做 iOS**）  
**UI 语言：** 用户可见文案使用中文  

本文是权限注册表与 bridge 协议的正式规格。实现必须以本文的 `id` / Guest CLI / 默认级别为准；变更须同步改本文与设置页文案。

---

## 1. 设计原则

1. **Guest 薄 CLI，宿主厚实现**  
   沙箱内只提供 `vault-*` 命令入口（读 stdin/参数 → 调 bridge → 写 stdout/stderr + exit code）。真正的 OS API、插件、权限弹窗全部在宿主（Dart / Android / Windows）完成。

2. **Dart 为唯一注册表**  
   权限 `id`、所属组、默认级别、平台可用性由 Dart 侧 registry 定义；设置页与 smoke 测试都读同一份表。禁止在 Kotlin/C++ 里另维护一份「真相」。

3. **三级策略**  
   | 级别 | 含义 |
   |------|------|
   | `BYPASS` | 默认允许（仍受 OS 运行时权限与总开关约束） |
   | `ASK_ONCE` | 每个会话（或首次）需用户确认后放行 |
   | `NOT_ALLOWED` | 默认拒绝；仅用户在设置中显式打开后可用 |

4. **会话绑定**  
   Guest 进程须带环境变量 `VAULT_CHAT_SESSION_ID`（对应当前对话 / 沙箱会话）。宿主按该 ID 查会话级授权缓存与工作区上下文。缺失或未知 ID 时拒绝调用（exit `126`）。

5. **能力可发现、可统测**  
   每条能力有稳定 `id` + CLI 名；设置页按组展示，并提供 **「一键统测」** 对当前会话批量 smoke。

---

## 2. 权限组定义

| 组 id | 中文名（设置） | 说明 |
|-------|----------------|------|
| `privacy` | 隐私 | 剪贴板、日历、通讯录、相册、定位等个人数据 |
| `host` | 宿主文件 | 访问宿主侧文件/目录（非 guest rootfs） |
| `media` | 媒体 | TTS、语音识别、媒体播放 |
| `system` | 系统 | 通知、闹钟、设备信息、打开 URL、天气等 |
| `integrations` | 系统集成 | 无障碍、Shizuku 等高权限集成（默认关闭） |
| `config` | 配置 | Offload 总开关与配置读写（`vault-config`） |

---

## 3. 权限注册表

图例：

- **Android / Windows：** `是` = Wave 内实现；`延后` = 协议保留、本阶段不实现（CLI 应 exit `125`）；`—` = 不做  
- **OS deps：** 需要的系统/插件能力（实现时可细化）

| id | Guest CLI | 组 | 默认级别 | Android | Windows | OS deps |
|----|-----------|----|----------|---------|---------|---------|
| `clipboard` | `vault-clipboard` | privacy | BYPASS | 是 | 是 | 系统剪贴板 |
| `calendar` | `vault-calendar` | privacy | BYPASS | 是 | 是 | 日历读/写（平台日历 API） |
| `contacts` | `vault-contacts` | privacy | BYPASS | 是 | 是 | 通讯录读（平台 Contacts） |
| `photos` | `vault-photos` | privacy | BYPASS | 是 | 是 | 相册/媒体库读 |
| `location` | `vault-location` | privacy | ASK_ONCE | 是 | 是 | 定位（运行时权限） |
| `host_files` | `vault-host-files` | host | ASK_ONCE | 是 | 是 | 宿主文件系统（scoped / 用户选定路径） |
| `notification` | `vault-notification` | system | BYPASS | 是 | 是 | 本地通知；Android 需通知权限 |
| `alarm` | `vault-alarm` | system | BYPASS | 是 | 延后 | Android AlarmManager / 精确闹钟权限 |
| `device_info` | `vault-device` | system | BYPASS | 是 | 是 | 非敏感设备元数据（型号、OS 版本等） |
| `open_url` | `vault-open` | system | BYPASS | 是 | 是 | 用系统浏览器/默认应用打开 URL 或 URI |
| `weather` | `vault-weather` | system | BYPASS | 是 | 是 | 天气数据源（宿主实现；可依赖定位策略） |
| `speak` | `vault-speak` | media | BYPASS | 是 | 是 | TTS |
| `speech` | `vault-speech` | media | BYPASS | 是 | 是 | 语音识别 / STT |
| `player` | `vault-player` | media | BYPASS | 是 | 延后 | 媒体播放控制 |
| `a11y` | `vault-a11y` | integrations | NOT_ALLOWED | 是（骨架） | — | Android AccessibilityService 状态探测（Wave4；无 UI 自动化） |
| `shizuku` | `vault-shizuku` | integrations | NOT_ALLOWED | 是（骨架） | — | Shizuku 包检测骨架（无 AAR / binder） |
| `vault_config` | `vault-config` | config | 总开关默认开 | 是 | 是 | 允许写 provider/API key/model；**禁止读回密钥**；总开关默认 **开** |

说明：

- `device_info` 的 Guest CLI 名为 **`vault-device`**（不是 `vault-device-info`）。  
- `vault_config` 控制 Offload **总开关**（默认开），并允许写入 provider / API key / model；**禁止读回密钥**。关闭总开关后所有 `vault-*`（除用于重新打开配置的最小路径，若实现需要则单独约定）应拒绝。  
- `a11y` / `shizuku` 仅 Android；Windows 调用返回 `unsupported_platform`（125）。  
- **Wave4 骨架用法（Android）：**
  - 注册表默认仍为 `NOT_ALLOWED`（Agent 不会放行）；一键统测勾选「含高风险集成」后才会跑这两项。
  - `vault-a11y smoke|status`：查 `Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES` 是否含 `com.vault.vault/.offload.VaultAccessibilityService`。未启用 → exit **1** + JSON（含 `settingsAction`），**不是** 125。启用路径：系统设置 → 无障碍 → 已安装的应用 → **Vault**。
  - `vault-shizuku smoke|status`：不捆绑 Shizuku AAR；检测 manager 包是否安装，exit **0** + `{ok, available, limited:true, note}`。

---

## 4. 协议

### 4.1 调用路径

```
guest: vault-<name> [args] / stdin
    → bridge（带 VAULT_CHAT_SESSION_ID）
    → Dart registry：总开关 → 组/项级别 → 会话授权缓存
    → 平台实现（Android MethodChannel / Windows 原生桥）
    → stdout JSON 或纯文本 + exit code
```

### 4.2 Exit codes（约定）

| Exit | Token（stderr 首行或结构化字段） | 含义 |
|------|----------------------------------|------|
| `0` | （成功） | 调用成功 |
| `126` | `permission_denied` | 注册表拒绝、用户未授权、总开关关、会话无效 |
| `125` | `unsupported_platform` | 当前平台未实现或明确不做（如 Windows 上的 `a11y`，或「延后」项） |

其它非零码留给实现错误 / 参数错误；**权限与平台不可用必须用 126 / 125**，便于 Agent 与「一键统测」区分。

### 4.3 环境变量

| 变量 | 必需 | 说明 |
|------|------|------|
| `VAULT_CHAT_SESSION_ID` | 是 | 当前聊天 / 沙箱会话 ID；宿主据此绑定授权与工作区 |

---

## 5. 设置页信息架构（IA）

路径建议：**设置 → API 权限 / Native Offload**（中文）。

```
设置
└── API 权限（Native Offload）
    ├── 总开关（vault_config，默认开）
    ├── 隐私（privacy）
    │   ├── 剪贴板 / 日历 / 通讯录 / 相册 / 定位 …
    ├── 宿主文件（host）
    ├── 媒体（media）
    ├── 系统（system）
    ├── 系统集成（integrations）   ← 默认 NOT_ALLOWED，醒目风险说明
    └── [一键统测]                 ← 对当前会话批量 smoke
```

**「一键统测」：**

- 用户可见按钮文案：**一键统测**  
- 针对**当前会话**注入 `VAULT_CHAT_SESSION_ID`，按注册表逐项（或按已实现 Wave）调用对应 `vault-*` 的最小探测子命令  
- 汇总展示：通过 / `permission_denied`(126) / `unsupported_platform`(125) / 其它错误  
- 不替代单元测试；用于真机 / 本机 bridge 冒烟

---

## 6. 实施波次（Wave 0–4）

| Wave | 范围 | 状态 |
|------|------|------|
| **0** | 桥 + 权限核 + Settings壳 + 一键统测框架；协议 125/126；`VAULT_CHAT_SESSION_ID` | 已落地 |
| **1** | `clipboard`、`device_info`（`vault-device`）、`open_url`（`vault-open`）、`notification` | 已落地 |
| **2** | `calendar`、`contacts`、`photos`、`location` | 已落地（Android Kotlin + Windows Dart handlers + shared wiring） |
| **3** | `host_files`、`vault_config`、`speak`、`speech`；（`player`/`alarm` 按平台） | 已落地（host_files / vault_config / speak / speech） |
| **4** | Android `a11y`、`shizuku`（可选）；统测扩表 | 骨架已落地（status/smoke；默认 NOT_ALLOWED） |

**进度：** Wave0–3 已落地；Wave4（a11y / shizuku）Android 骨架已落地（status/smoke；无障碍服务需用户在系统设置中启用；Shizuku 未捆绑 AAR，仅包检测；Windows 仍 125 / 未实现）。

每波须同时更新：设置中文文案、一键统测覆盖列表；未实现或「延后」项保持 exit `125`。

---

## 7. Non-goals（明确不做）

- **iOS / macOS** bridge 或权限组  
- 在 guest 内直接弹 OS 权限框或嵌入完整 SDK  
- 绕过 Dart registry 的 ad-hoc MethodChannel / 私有协议  
- 把 Offload 做成独立常驻微服务或第二套 Agent 运行时  
- Play 上架相关的权限合规包装（项目侧载 / GPLv3 基线不变）  
- 本阶段实现 Windows `alarm` / `player`（协议位保留，exit 125）  
- 将 `integrations`（a11y / shizuku）默认改为放行  

---

## 8. 与 backlog 的关系

- 进度与勾选：[`feat.md`](./feat.md) **F8**  
- 沙箱约束不变：一会话一 Alpine；CLI 跑在 guest 内，经已有会话通道回宿主  
- Agent（F1）可通过 shell 工具调用 `vault-*`；权限拒绝应表现为可理解的中文/结构化错误，便于模型重试或向用户说明  
