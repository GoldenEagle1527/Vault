# Vault Android MVP 报告

**状态：** 已验收通过  
**日期：** 2026-08-08  
**平台：** Android arm64 + Flutter 3.41.9（targetSdk 35，侧载）  
**许可：** GPLv3  

---

## 1. 目标与范围

为每个 Agent 会话提供**独立的 Linux 沙箱**，Android 端采用「一会话一份 Alpine rootfs + patched proot」：

| 能力 | MVP 结果 |
|------|----------|
| 创建 / 附着 / 删除会话 | ✅ |
| 交互终端（PTY + xterm，软键盘） | ✅ |
| Alpine + `apk` | ✅ |
| 每会话独立 rootfs（非共享 rootfs + bind） | ✅ |
| jniLibs `libproot.so` + `PROOT_LOADER`（targetSdk 35） | ✅ |
| 前台服务保活（通知「Vault 会话运行中」） | ✅（已接入） |
| 中文 UI | ✅ |
| Play 上架 | ❌ 不做（仅侧载） |
| Agent 编排层 | ❌ 未开始（M4） |

成功标准（与计划一致）：真机新建会话 → Alpine shell → `apk` → 中文 UI；GPLv3 侧载说明齐全。

---

## 2. 交付物

```
lib/sandbox/
  sandbox_models.dart / sandbox_provider.dart
  proot_provider.dart       # Android 完整实现
  proot_host.dart           # MethodChannel 封装
  rootfs_extract.dart       # 绝对 symlink 改写 + chmod
  wsl_provider.dart         # Windows（不变）
android/app/src/main/
  jniLibs/arm64-v8a/libproot.so
  jniLibs/arm64-v8a/libproot-loader.so
  kotlin/.../ProotPlugin.kt
  kotlin/.../SessionForegroundService.kt
  kotlin/.../MainActivity.kt
assets/rootfs/android/
  alpine-prootdistro-aarch64.tar.gz
third_party/oonid-pr/       # 参考树 @ 1f6b10f
scripts/build_android_proot.sh
docs/android-m2-matrix.md
docs/android-mvp-plan.md
THIRD_PARTY_LICENSES.md / README.md
```

**构建产物：**

| 产物 | 路径 |
|------|------|
| Debug APK | `build/app/outputs/flutter-apk/app-debug.apk`（约 100 MB） |

**关键版本：**

| 项 | 值 |
|----|-----|
| proot（oonid/pr） | `1f6b10f726868aa2648000bb576ceb4753d31b77` |
| proot 构建 | 上游预编译 jniLibs，NDK **r27c**，LOAD Align **0x4000（16KB）** |
| rootfs | proot-distro Alpine aarch64 **pd-v4.37.0** |
| 来源 URL | `https://easycli.sh/proot-distro/alpine-aarch64-pd-v4.37.0.tar.xz` |
| SHA256 | `2bdfb03eae53e6163695f4cd3b86e67ddca78466c879a140e069b1263150599b` |
| minSdk / targetSdk | 26 / 35 |
| ABI | 仅 `arm64-v8a` |

**运行 / 安装：**

```bash
./scripts/build_android_proot.sh --use-prebuilt   # 若 jniLibs 缺失
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

---

## 3. 架构（Android）

```
Flutter UI（会话列表 + xterm，中文）
        │
        ▼
   ProotProvider
        │
        ├── assets → files/sessions/<id>/rootfs（独立解压）
        ├── MethodChannel vault.sandbox/proot
        │     · nativeLibraryDir / filesDir / pageSize
        │     · Foreground Service / 电池优化设置
        ├── flutter_pty → nativeLibraryDir/libproot.so
        │     env: PROOT_LOADER=.../libproot-loader.so
        │     args: --link2symlink --kill-on-exit --change-id=0:0
        │           --rootfs=<会话 rootfs> --bind /dev|/proc|/sys …
        └── destroy：杀 PTY + 删除会话目录
```

元数据：`files/sessions/sessions.json`。  
Guest 二进制由 **PROOT_LOADER** 加载（绕过 `app_data_file` 不可 exec）；proot/loader 本身必须在 `nativeLibraryDir`（`extractNativeLibs` / `useLegacyPackaging`）。

---

## 4. 验收记录

真机侧载 debug APK 后，在会话终端内验证通过：

1. `uname -a` / `id` / `pwd` → Linux Alpine、假 root（`uid=0`）、`/root`
2. `ls /bin/sh` `/bin/busybox` → 存在
3. `apk update` → 可用
4. `apk add curl` → 可用
5. 网络（如 `curl`）→ 可用
6. 新建会话 → 终端交互 → 删除会话 → 路径可用

矩阵见 [`android-m2-matrix.md`](./android-m2-matrix.md)。

**隔离边界（需在产品说明中诚实告知）：**

- 磁盘：每会话一份完整 rootfs（数十～上百 MB 量级，视已装包而定）
- 安全：文件系统级会话隔离；**无**真 PID / 网络 / mount namespace；与宿主共享内核与网络栈
- 性能：proot 有约 20–30% 开销
- 分发：仅侧载，不上 Play

---

## 5. 遇到的问题与解决方式

### 5.1 Windows 宿主难以从源码编出 loader

**现象：** oonid/pr 公开树缺少 `src/proot/src/loader/`；Windows scoop Make 对带空格的 `SHELL` 与 `USE_BUILD_H` 的 `egrep [[:space:]]` 不友好。  
**处理：** MVP 使用上游已发布、16KB 页对齐的预编译 `libproot.so` / `libproot-loader.so`；`scripts/build_android_proot.sh` 默认 `--use-prebuilt`，保留 `--from-source`。

### 5.2 talloc / samba pin

从源码构建时 samba HEAD 为 talloc 2.5，与 stub 的 2.4 不匹配。oonid 锁定 samba `2f8dfde`。预编译路径不涉及此问题。

### 5.3 解压后缺少 `/bin/sh`

**原因：** Alpine 中 `/bin/sh` → `/bin/busybox` 为**绝对**符号链接。`package:archive` 的 `extractFileToDisk` 拒绝绝对 symlink（防 zip-slip），链接被静默跳过。  
**处理：** `lib/sandbox/rootfs_extract.dart` 将绝对 guest 链接改写为相对链接（如 `busybox`），并扁平化 tarball 顶层 `alpine-aarch64/`。

### 5.4 `proot error: 'bin/sh' is not executable`

**原因：** 自定义解压未保留 Unix 执行位；proot 在宿主侧 `stat` 检查 `S_IXUSR`。  
**处理：** 解压后按条目 `chmod`，并对 `bin/`、`usr/bin/` 等做 `0755` 兜底。

### 5.5 SELinux / targetSdk 35

**约束：** 不可对 `files/` 内普通二进制 `execve`；必须用 jniLibs 中的 `libproot.so` + `libproot-loader.so`，且 `extractNativeLibs=true`（`useLegacyPackaging=true`）。  
**假 root：** `--change-id=0:0`，否则 `apk` 权限失败。

### 5.6 rootfs 选择（16KB 页）

**禁止**单独依赖 Windows 用的上游官方 Alpine aarch64 minirootfs 作为 Android 唯一 rootfs。  
**采用** proot-distro 系 Alpine tarball（与 oonid/pr 插件同源）。

---

## 6. 关键配置摘要

### 6.1 Gradle / Manifest

- `minSdk = 26`，`targetSdk = 35`
- `ndk.abiFilters = ["arm64-v8a"]`
- `packaging.jniLibs.useLegacyPackaging = true`
- `android:extractNativeLibs="true"`
- 权限：`INTERNET`、`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_SPECIAL_USE`、`POST_NOTIFICATIONS`、`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`

### 6.2 典型 proot 启动参数

```text
libproot.so
  --link2symlink
  --kill-on-exit
  --change-id=0:0
  --rootfs=<files/sessions/<id>/rootfs>
  --cwd=/root
  --bind=/dev
  --bind=/proc
  --bind=/sys
  --bind=<rootfs>/tmp:/dev/shm
  /bin/sh -l
```

环境：`PROOT_LOADER=<nativeLibraryDir>/libproot-loader.so`，`PROOT_NO_SECCOMP=1` 等。

---

## 7. 如何验证（复现步骤）

1. 安装 APK：`adb install -r build/app/outputs/flutter-apk/app-debug.apk`
2. 打开 Vault → 确认能力卡片显示 proot 就绪（含页大小）
3. **新建会话** → 进入终端
4. 执行：

   ```sh
   uname -a
   id
   pwd
   apk update
   apk add curl
   ```

5. （建议）第二会话验证 `/root/mark.txt` 与软件包互不可见  
6. （建议）会话中灭屏数分钟后回前台，确认 shell 仍在；通知栏可见「Vault 会话运行中」  
7. 删除会话，确认磁盘回收、列表更新  

主机：

```bash
adb shell getprop ro.product.model
adb shell getconf PAGE_SIZE
adb logcat | grep -i proot
```

---

## 8. 已知限制与后续

| 项 | 说明 |
|----|------|
| ABI | MVP 仅 arm64-v8a |
| 命名空间 | 无真 PID/网络/mount 隔离 |
| 性能 | proot 约 20–30% 开销 |
| 后台 | 依赖 FGS 通知；激进厂商仍可能杀进程，需引导关电池优化 |
| 设备矩阵 | 多机型 / 16KB 页档位建议继续补测（见矩阵文档） |
| Release 签名 | 当前 release 仍可用 debug 签名；发版前换正式签名 |
| Agent 编排 | M4，跨平台 |
| 从源码复现 proot | 待 oonid 公开完整 loader 源或改用 submodule 拼齐 |

---

## 9. 给后续 Agent 的指针

- Android 实现以 `lib/sandbox/proot_provider.dart` + `rootfs_extract.dart` 为准  
- 勿把 Windows 的 `assets/rootfs/alpine-minirootfs-aarch64.tar.gz` 当作 Android 唯一 rootfs  
- 勿把 proot 放进 assets 再 chmod 执行  
- 终端：`lib/widgets/session_terminal.dart`（非桌面 `hardwareKeyboardOnly: false`）  
- 下一步：M4 Agent 编排；补全多设备矩阵与正式 release 签名侧载流程  
