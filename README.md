# Vault

Flutter 应用：为每个 Agent 会话提供**隔离的 Linux 沙箱**。

| 平台 | 后端 | 状态 |
|------|------|------|
| Windows | 每会话一个 WSL2 发行版（Alpine） | **MVP 已验收** |
| Android | patched proot + Alpine（jniLibs） | 计划中，见下文 |

许可：**GPLv3**（见 `LICENSE`、`THIRD_PARTY_LICENSES.md`）。Android 仅 GitHub Releases 侧载。

## 文档

- [Windows MVP 报告](docs/windows-mvp-report.md) — 交付物、验收、踩坑与修复  
- [Android MVP 开发计划](docs/android-mvp-plan.md) — **给新 Agent 的完整执行单（M2 门禁 → M3）**

## Windows 运行

前置：已安装 WSL2（`wsl --install`）。

```bash
flutter pub get
flutter run -d windows
```

## 工程结构

```
lib/sandbox/     SandboxProvider / WslProvider / ProotProvider
lib/screens/     首页 + 终端（中文）
lib/widgets/     xterm SessionTerminal
assets/rootfs/   Windows 用 Alpine minirootfs
docs/            MVP 报告与 Android 计划
```
