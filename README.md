# Vault

Flutter 应用：为每个 Agent 会话提供**隔离的 Linux 沙箱**。

| 平台 | 后端 | 状态 |
|------|------|------|
| Windows | 每会话一个 WSL2 发行版（Alpine） | **MVP 已验收** |
| Android | patched proot + Alpine（jniLibs） | **MVP 已验收** |

许可：**GPLv3**（见 `LICENSE`、`THIRD_PARTY_LICENSES.md`）。Android 仅侧载，不上 Play。

## 文档

- [Windows MVP 报告](docs/windows-mvp-report.md)
- [Android MVP 报告](docs/android-mvp-report.md) — 交付物、验收、踩坑与安装
- [Android MVP 开发计划](docs/android-mvp-plan.md)
- [Android M2 设备矩阵](docs/android-m2-matrix.md)

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

安装后打开应用 → 新建会话 → 终端内验证 `uname -a` / `apk update`。  
长任务请保留「Vault 会话运行中」通知，并按提示关闭电池优化。

## 工程结构

```
lib/sandbox/          SandboxProvider / WslProvider / ProotProvider
lib/screens/          首页 + 终端（中文）
lib/widgets/          xterm SessionTerminal
assets/rootfs/        Windows Alpine；android/ 下为 proot-distro Alpine
android/.../jniLibs/  libproot.so + libproot-loader.so
third_party/oonid-pr/ vendored patched proot 参考树
scripts/              build_android_proot.sh 等
docs/                 MVP 报告与计划
```
