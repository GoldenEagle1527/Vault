# Android M2 设备矩阵

**日期：** 2026-08-08  
**结论：** M2a / M2b 门禁通过（真机侧载验收）；见 [`android-mvp-report.md`](./android-mvp-report.md)  
**proot：** oonid/pr `1f6b10f726868aa2648000bb576ceb4753d31b77`（预编译 jniLibs，NDK r27c，LOAD Align `0x4000`）  
**rootfs：** `assets/rootfs/android/alpine-prootdistro-aarch64.tar.gz`（proot-distro Alpine aarch64 pd-v4.37.0）  
**APK：** `flutter build apk --debug` → `build/app/outputs/flutter-apk/app-debug.apk`（targetSdk 35，abiFilters arm64-v8a）

---

## 门禁结论

| 项 | 状态 |
|----|------|
| M2a 编译/安装 `.so` + debug APK | **通过** |
| M2b 真机 shell + `apk` | **通过**（侧载 debug APK，应用内新建会话） |
| M2c 矩阵覆盖 | **部分** — 至少一档真机验收通过；建议继续补 4KB/16KB 与多 Android 版本 |

---

## 设备表

| 型号 | Android | 页大小 | targetSdk | sh 冒烟 | apk 冒烟 | 备注 |
|------|---------|--------|-----------|---------|----------|------|
| 验收真机（侧载） | （用户环境） | （见能力卡片 / `getconf`） | 35 | **通过** | **通过**（`apk update` / `apk add curl`） | 2026-08-08；`uname`/`id`/`pwd`/网络 OK |

目标档（有设备继续补）：

- Android 10 / 12 / 14
- Android 15 QPR2 / 16
- 4KB 与 16KB 页各至少一档（若只有一档，发版说明中写明风险）

---

## 验收命令（已跑通）

```sh
uname -a
id
pwd
ls /bin/sh /bin/busybox
apk update
apk add curl
```

主机：

```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell getprop ro.product.model
adb shell getconf PAGE_SIZE
```
