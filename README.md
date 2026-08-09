# Vault

Flutter 应用：为每个 **工作区** 提供隔离的 Linux 沙箱，工作区内可开启多轮 **会话**（Agent 对话）。

| 平台 | 后端 | 状态 |
|------|------|------|
| Windows | 每工作区一个 WSL2 发行版（Alpine） | **MVP 已验收** |
| Android | patched proot + Alpine（jniLibs） | **MVP 已验收** |

许可：**GPLv3**（见 `LICENSE`、`THIRD_PARTY_LICENSES.md`）。Android 仅侧载，不上 Play。

## 文档

- [**工作区与会话存储**](docs/workspace-and-conversation-storage.md) — 概念、目录布局、`workspaces.json` / `agent_states`、删除语义、ID 对照
- [未完成特性 backlog](docs/feat.md) — 跨工作区维护：文件浏览器 / 矩阵 / 测试等
- [Agent 接入 MVP 报告](docs/agent-mvp-report.md) — 编排引擎、BYO API、shell、附件 inbox
- [Windows MVP 报告](docs/windows-mvp-report.md)
- [Android MVP 报告](docs/android-mvp-report.md) — 交付物、验收、踩坑与安装
- [Android MVP 开发计划](docs/android-mvp-plan.md)
- [Android M2 设备矩阵](docs/android-m2-matrix.md)

## 工作区与会话（摘要）

产品模型是 **1 工作区 : N 会话**：

- **工作区** = 一套独立 Alpine（Windows WSL 发行版 / Android proot rootfs），首页列表中的一行。
- **会话** = 工作区内的 Agent 对话线程；共享同一 Linux 文件系统，各自独立对话上下文。

落盘（细节与 schema 见 [存储文档](docs/workspace-and-conversation-storage.md)）：

| 数据 | 位置 |
|------|------|
| 工作区元数据 | 主机 `workspaces.json`（Windows：`…/wsl_distros/`；Android：`…/workspaces/`） |
| 沙箱磁盘 | Windows：WSL 发行版；Android：`workspaces/{workspaceId}/rootfs/` |
| **会话 + AgentState** | **Linux 内** `/root/.vault/conversations/`（`index.json` + `{conversationId}.json`） |
| API Key 等 | `flutter_secure_storage`（不进上述 JSON） |

会话与沙箱同生共死：删除工作区即销毁全部对话。主机侧旧目录 `agent_states/` / `sessions.json` **不兼容**。

## Windows 运行

前置：已安装 WSL2（`wsl --install`）。

```bash
flutter pub get
flutter run -d windows
```

## Android（侧载）

前置：arm64 真机，USB 调试；最低 Android 8.0（API 26），APK `targetSdk` 35。

```bash
# 安装 oonid/pr 预编译 proot 到 jniLibs（默认）
./scripts/build_android_proot.sh --use-prebuilt

flutter pub get
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

安装后打开应用 → 新建工作区 → 终端内验证 `uname -a` / `apk update`。  
工作区初始化会自动将 Alpine apk 源切换为国内镜像（阿里云），无代理也可下载软件包。  
长任务请保留「Vault 工作区运行中」通知，并按提示关闭电池优化。

## Agent（F1）

编排引擎是仓库内自有模块 [`packages/vault_agent_core`](packages/vault_agent_core/)（从 [dart_agent_core](https://github.com/memex-lab/dart_agent_core) 收编并改名，见该目录 `UPSTREAM.md`）。

- **不要** `flutter pub add dart_agent_core` / 不要依赖 pub.dev 上的上游包。
- 根 `pubspec.yaml` 使用本地 `path: packages/vault_agent_core`。
- 用法：首页设置 API Base / Key / Model → 打开工作区 → 在会话中下发任务；shell 只在对应工作区的 Alpine Linux 内执行。
- 附件：Agent 界面可附加文件，发送前写入该工作区的 `/root/inbox/`，模型只能看到 guest 路径。
- 同一工作区内可新建多条会话；会话各自独立对话上下文，共享同一 Linux 文件系统。
- 会话在 Agent 回合中经 `autoSaveStateFunc` 自动落盘，重开工作区可恢复气泡与模型上下文。

## 工程结构

```
packages/vault_agent_core/  自有 Agent 引擎（vendored fork，非 pub.dev）
lib/agent/                  Vault 适配层（settings / shell / conversation store）
lib/sandbox/                SandboxProvider / WslProvider / ProotProvider（工作区）
lib/screens/                首页 + 终端 + Agent + 设置（中文）
lib/widgets/                xterm WorkspaceTerminal
assets/rootfs/              Windows Alpine；android/ 下为 proot-distro Alpine
android/.../jniLibs/        libproot.so + libproot-loader.so
third_party/oonid-pr/       vendored patched proot 参考树
scripts/                    build_android_proot.sh 等
docs/                       概念文档、MVP 报告与计划
```
