# Vault Android MVP 开发计划（给新 Agent 的完整执行单）

**前置：** Windows MVP 已验收，见 [`windows-mvp-report.md`](./windows-mvp-report.md)  
**仓库：** `H:\Projects\Vault`（Flutter 工程名 `vault`，组织 `com.vault`）  
**许可约束：** GPLv3；Android **仅 GitHub Releases 侧载**，不上 Play  
**策略：** 复用 patched proot fork（oonid/pr），**不要**从 upstream 自己重打全部补丁  

---

## 0. 你必须先读的上下文

1. 本文全文  
2. `docs/windows-mvp-report.md`（编码、隔离、UI 模式）  
3. `lib/sandbox/sandbox_provider.dart` + `sandbox_models.dart`（**禁止改坏抽象**）  
4. `lib/sandbox/proot_provider.dart`（当前占位，你要替换）  
5. `lib/widgets/session_terminal.dart`、`lib/screens/home_screen.dart`（复用 UI）  
6. 参考实现：https://github.com/oonid/pr （尤其 `src/proot/`、jniLibs 布局、PROOT_LOADER）  

**产品决策（已定，勿再问）：**

- Android 沙箱 = vendored patched proot + jniLibs，**不是** assets+chmod  
- 分发 = 侧载；可接受 GPL  
- 每会话**独立 rootfs**（不要「共享 rootfs + `-b` 工作区」冒充隔离）  
- UI 语言 = **中文**（与 Windows 一致）  

**硬门禁：** M2（真机 proot 冒烟）未通过 → **禁止**进入 M3 UI/会话逻辑投入。

---

## 1. 当前仓库状态（起点）

已有：

- Flutter android + windows 工程  
- `SandboxProvider` / `SandboxSession` 抽象  
- `WslProvider` 完整；`ProotProvider` 仅 stub（`probe()` 返回 unavailable）  
- 依赖：`flutter_pty`、`xterm`、`path_provider`、`archive`、`uuid`、`path`  
- Windows 用的 Alpine minirootfs 在 `assets/rootfs/` —— **Android 不要直接用这份上游 aarch64**（见 §3.3）  

你要做的：把 Android 从 stub 做到与 Windows 同级的「会话列表 + 终端 + 创建/删除」。

---

## 2. 里程碑总览

| ID | 名称 | 通过标准 | 失败时 |
|----|------|----------|--------|
| **M2a** | 编译出 `libproot.so` + `libproot-loader.so` | NDK 构建成功，装入 `jniLibs/arm64-v8a/` | 修构建，勿跳过 |
| **M2b** | 真机 spike（可无正式 UI） | targetSdk 35 设备上 proot 内跑通 `/bin/sh` 与简单命令 | 记入矩阵；目标机型全挂则停并升级决策 |
| **M2c** | 设备矩阵记录 | 至少覆盖计划中的页大小档；写 `docs/android-m2-matrix.md` | 部分失败则缩小支持声明 |
| **M3a** | `ProotProvider` 生命周期 | create/attach/destroy/list + 每会话独立 rootfs | — |
| **M3b** | 接入现有 UI | 同 Windows：首页会话、终端、中文；`apk add` 双会话隔离 | — |
| **M3c** | 前台服务 | 亮灭屏 / 后台数分钟任务不被杀 | — |
| **M3d** | 打包侧载 APK | `flutter build apk`，文档说明安装方式 | — |

M4（Agent 编排）**不在本计划**；本计划结束于 Android 沙箱 MVP 可用。

---

## 3. 致命约束（写进代码前背下来）

### 3.1 不能执行 app 私有目录里的普通二进制

`targetSdk >= 29` 时，SELinux 禁止对 `app_data_file` 做 `exec`。因此：

- ❌ `assets/` 复制 proot → `files/` → `chmod +x` → `Process.start`  
- ✅ proot 以 **`libproot.so` / `libproot-loader.so`** 放在 `jniLibs`，运行时路径在 `nativeLibraryDir`（可执行）  
- ✅ guest ELF 由 **PROOT_LOADER** mmap 执行，而不是内核直接 `execve` guest 路径  

`AndroidManifest` / `build.gradle`：保证 **`android:extractNativeLibs="true"`**（或等效），否则 `.so` 可能不落盘为可执行文件。

### 3.2 seccomp / 页面大小

- Zygote seccomp 会挡一批 syscall → 必须用带 SIGSYS 处理的 **patched proot**（oonid/pr 路线）  
- Android 15 QPR2+ / 16 常见 **16 KB 页**：proot **必须** `--with-page-size=16384` 构建  
- 上游 Alpine aarch64 minirootfs 多为 4 KB 对齐 → 新设备上 `Exec format error`  

### 3.3 Rootfs 选择

- **使用 proot-distro 重建的 Alpine aarch64 tarball**（或 oonid/pr 文档/脚本指向的同源产物）  
- **禁止**把 Windows 的 `assets/rootfs/alpine-minirootfs-aarch64.tar.gz`（上游官方）当作 Android 16KB 设备的唯一 rootfs，除非矩阵证明可用  
- 建议路径：`assets/rootfs/android/alpine-prootdistro-aarch64.tar.gz`（名称可自定，但与 Windows 资产分离）  

### 3.4 假 root

启动 proot 时带 **`--change-id=0:0`**（及 fork 要求的配套参数），否则 `apk` 会因权限失败。具体参数以 oonid/pr 的可用命令行为准，对齐后再封装进 Dart。

### 3.5 架构

MVP 只保证 **`arm64-v8a`**。不要为了「完整」先铺 armeabi-v7a，除非矩阵明确要求。

---

## 4. M2a — 构建 patched proot

### 4.1 获取源码

推荐（二选一，优先 A）：

**A. git submodule**

```bash
cd H:/Projects/Vault
git submodule add https://github.com/oonid/pr.git third_party/oonid-pr
# 若暂无 git 远程，可 git init 后再 add；或改为浅克隆：
# git clone --depth 1 https://github.com/oonid/pr.git third_party/oonid-pr
```

**B. 只 vendoring `src/proot/`**  
复制进 `third_party/proot/` 并保留其 LICENSE（GPL-2.0）与构建脚本说明。

**不要**引入其 Rust `pr-cli` 作为构建依赖；安装/解压逻辑用 Dart/Kotlin 重写。

### 4.2 NDK 构建

- NDK：**r27c 或更新**（需支持 16KB）  
- 产出目标：

```
android/app/src/main/jniLibs/arm64-v8a/libproot.so
android/app/src/main/jniLibs/arm64-v8a/libproot-loader.so
```

- 构建选项必须包含 **`--with-page-size=16384`**（或该 fork 文档中的等价 CMake/Make 变量）  
- 将可复现步骤写入 `scripts/build_android_proot.sh`（或 `.ps1`），并在 README/本目录链到脚本  

### 4.3 Gradle / Manifest 检查清单

- [ ] `minSdk` ≥ 26（建议；与计划一致）  
- [ ] `targetSdk` = 35（或工程当前 Flutter 默认，**不要为了偷懒降到 28**，除非 M2 失败后走决策分支）  
- [ ] `extractNativeLibs=true`  
- [ ] abiFilters 仅 `arm64-v8a`（MVP）  
- [ ] 更新 `THIRD_PARTY_LICENSES.md`：proot GPL-2.0、talloc LGPL、rootfs/插件来源  

### 4.4 M2a 完成定义

- [ ] 两份 `.so` 存在于 jniLibs  
- [ ] `flutter build apk --debug` 能打包进 APK  
- [ ] 文档记录 NDK 版本与精确构建命令  

---

## 5. M2b — 真机 Spike（门禁）

### 5.1 目标

**最小可行证明**，允许临时 Activity / 仅 `adb logcat` / 甚至 Kotlin 小按钮，**不要求**接好 xterm。

必须证明：

1. 从 `nativeLibraryDir` 启动 `libproot.so`  
2. 环境变量 `PROOT_LOADER=<nativeLibraryDir>/libproot-loader.so`  
3. 解压 Android 版 Alpine rootfs 到 `filesDir`（或 `getFilesDir()`）  
4. 在 proot 内执行成功：

   ```sh
   /bin/sh -c 'echo SPIKE_OK; uname -a; id'
   ```

5. （加分）`apk update` 或至少 `ls /bin` 正常  

### 5.2 推荐启动参数（需与 fork 对齐后固化）

伪命令（以实机调通的为准，调通后写进 `ProotProvider`）：

```text
$NATIVE/libproot.so
  --link2symlink
  --kill-on-exit
  --change-id=0:0
  -r <rootfs>
  -b /dev
  -b /proc
  -b /sys
  -w /root
  /bin/sh -l
```

`PROOT_LOADER` 必须在环境中。若 fork 使用不同 flag 名，以 fork README/测试为准。

### 5.3 获取 nativeLibraryDir（Kotlin MethodChannel）

新增精简 channel，例如 `vault.sandbox/proot`：

| method | 业务 |
|--------|------|
| `getNativeLibraryDir` | 返回 `applicationInfo.nativeLibraryDir` |
| `extractRootfs` | 从 assets 解压到 `files/sessions/<id>/rootfs`（可用 Dart `archive` 也行，二选一，保持一种） |
| `getFilesDir` | 应用私有目录 |

Dart 侧 **不要**硬编码 `/data/data/com.xxx/...`。

### 5.4 Spike 失败时的决策树（写进矩阵结论）

| 情况 | 动作 |
|------|------|
| 仅 16KB 设备失败、4KB 成功 | 收窄支持或换 16KB rootfs；**先修 rootfs/页大小再谈 UI** |
| 全部 targetSdk 35 失败 | 停 M3；选项：Termux `RUN_COMMAND` 委托 / 评估 targetSdk 28 仅侧载（需产品确认） |
| 能 sh 不能 apk | 查 `--change-id`、网络、DNS、`/etc/resolv.conf` bind |

---

## 6. M2c — 设备矩阵

创建并填写：`docs/android-m2-matrix.md`

最少记录列：

- 设备型号 / Android 版本 / 页大小（`getconf PAGE_SIZE` 或 API）  
- targetSdk  
- sh 冒烟：通过/失败 + log 摘要  
- apk 冒烟：通过/失败  
- 备注  

目标档（有设备就测，没有则注明「无设备」）：

- Android 10、12、14  
- Android 15 QPR2、16  
- 4KB 与 16KB 页各至少一档（若只有一档，写明风险）  

---

## 7. M3a — 实现 `ProotProvider`

替换 `lib/sandbox/proot_provider.dart`，实现完整 `SandboxProvider`。

### 7.1 行为对照 Windows

| API | Android 行为 |
|-----|----------------|
| `probe()` | 检查 arm64、nativeLibraryDir 下 so 是否存在、页大小、rootfs asset 是否存在；失败给**中文** hint |
| `create(id)` | 新建 `files/sessions/<id>/rootfs`，解压 Alpine，写元数据，返回已 attach 的 session |
| `attach(id)` | 校验 rootfs 存在，启动 PTY+proot |
| `destroy(id)` | 杀进程（若有）、删除会话目录、更新元数据 |
| `list()` | 读元数据 + 目录存在性；可显示大致磁盘占用 |

元数据可参考 Windows：`sessions.json`（路径用 `path_provider`）。

### 7.2 `ProotSession`

实现 `SandboxSession`：

- 用 `flutter_pty`：`Pty.start(prootPath, arguments: [...], environment: {PROOT_LOADER: loaderPath, ...})`  
- `output` / `write` / `resize` / `exitCode` / `dispose` 对齐 `WslSession`  
- `run(cmd)`：可再起一次性 proot 非交互进程（`Process.start` 跑同一 proot 二进制 + `-c`），**不要**把 `Process` 暴露出抽象层  

### 7.3 会话隔离验收

两会话 A/B：

- [ ] A：`echo A > /root/mark.txt`；B：`cat` 失败  
- [ ] B：`apk add nano`；A：`command -v nano` 无  
- [ ] destroy B 后磁盘回收，A 仍可用  

### 7.4 `createSandboxProvider()`

`Platform.isAndroid` → `ProotProvider()`（已有骨架，确认无误）。

---

## 8. M3b — UI 接入

- 复用 `HomeScreen` / `TerminalScreen` / `SessionTerminal`  
- Android：`SessionTerminal` 已对非桌面设 `hardwareKeyboardOnly: false`（确认 IME 可用）  
- 文案保持中文；`probe()` notes 写清：侧载、磁盘、无 Play  
- 能力卡片在 Android 上显示 proot / 页大小 / 是否就绪  

验收：与 Windows 相同的用户路径——新建会话 → 终端 → apk → 删除。

---

## 9. M3c — 前台服务与保活

长任务（agent / `apk` / 编译）在后台会被杀。

必做：

1. Kotlin **Foreground Service** + 常驻通知（中文：「Vault 会话运行中」）  
2. 有会话存活时启动服务；全部销毁后停止  
3. 引导关闭电池优化（`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 或设置页 Intent）——注意商店政策；我们是侧载，仍要克制，优先「打开设置」  
4. 验收：会话中跑 `sleep 180` 或长 `apk`，灭屏/切后台后进程仍在，回前台终端未死  

权限写入 Manifest，中文说明放进 `probe().notes` 或首次创建对话框。

---

## 10. M3d — 发布产物

```bash
flutter build apk --release
```

- 输出路径写入 `docs/android-mvp-report.md`（你完成后新建）  
- README 增加 Android 侧载安装步骤与最低系统要求  
- 再次确认 `THIRD_PARTY_LICENSES.md` 完整  

---

## 11. 明确不要做的事

- ❌ 为通过测试把 `targetSdk` 降到 28（除非 M2 失败且用户书面改决策）  
- ❌ 共享一个 rootfs 只用 bind 工作目录  
- ❌ 依赖 Termux 安装（本路线是自带 proot）  
- ❌ 引入 `workspace_sandbox` 当 Android 基础  
- ❌ 上 Play / 闭源绕过 GPL  
- ❌ 在 M2 未通过时大写 Flutter UI  
- ❌ 用 upstream Alpine minirootfs 冒充已解决 16KB 问题而不测  

---

## 12. 建议目录结构（完成后）

```
android/app/src/main/
  jniLibs/arm64-v8a/libproot.so
  jniLibs/arm64-v8a/libproot-loader.so
  kotlin/.../MainActivity.kt
  kotlin/.../ProotPlugin.kt          # MethodChannel + 可选 FGS
  kotlin/.../SessionForegroundService.kt
  assets/                            # 若 rootfs 放 Android assets
lib/sandbox/proot_provider.dart      # 完整实现
assets/rootfs/android/               # 16KB 友好 Alpine tarball
third_party/oonid-pr/ 或 proot/
scripts/build_android_proot.sh
docs/android-m2-matrix.md
docs/android-mvp-report.md           # 结束后撰写，格式可对标 windows-mvp-report
```

---

## 13. 执行顺序（给 Agent 的 TODO，请按序勾选）

复制到你的任务列表：

1. [ ] 阅读本文 + Windows 报告 + 现有 sandbox 抽象  
2. [ ] 引入 oonid/pr（submodule 或 vendoring），记录 commit hash  
3. [ ] 编写并跑通 `scripts/build_android_proot.sh`，产出 jniLibs  
4. [ ] 配置 extractNativeLibs、abi、targetSdk；打出 debug APK  
5. [ ] 准备 Android 专用 Alpine rootfs（proot-distro 系），打入 assets  
6. [ ] MethodChannel：`nativeLibraryDir` + 解压 rootfs  
7. [ ] Spike：真机 `SPIKE_OK`；记录 log  
8. [ ] 填写 `docs/android-m2-matrix.md`；**若门禁失败则停止并写明选项**  
9. [ ] 实现完整 `ProotProvider` + `ProotSession`  
10. [ ] 双会话隔离与 `apk` 验收  
11. [ ] 前台服务 + 灭屏保活验收  
12. [ ] 中文 UI 联调（复用现有页）  
13. [ ] `flutter build apk --release` + `docs/android-mvp-report.md`（问题/解决/验证步骤）  
14. [ ] 更新根 `README.md` 与 `THIRD_PARTY_LICENSES.md`  

---

## 14. 验收命令清单（Android 会话内）

与 Windows 对齐，便于写报告：

```sh
uname -a
id
pwd
echo $PATH
apk update
apk add curl
# 第二会话验证文件与包隔离
# 灭屏 3 分钟后回前台确认 shell 仍在
```

主机侧：

```bash
adb shell getprop ro.product.model
adb shell getconf PAGE_SIZE   # 若可用
adb logcat | grep -i proot
```

---

## 15. 完成后的报告要求

新建 `docs/android-mvp-report.md`，至少包含：

- 使用的 proot commit、NDK 版本、rootfs 来源 URL  
- M2 矩阵结论  
- 遇到的问题与解决（对标 Windows 报告 §5 风格）  
- 已知限制（性能 20–30%、无真 PID/网络 namespace、侧载等）  
- 如何安装 APK / 如何验证  

---

## 16. 一句话成功标准

**在 targetSdk 35 的 arm64 真机上，用户能像 Windows MVP 一样：新建会话 → 进 Alpine shell → `apk add` → 会话互不可见 → 删除回收；灭屏数分钟会话仍存活；全部中文 UI；GPLv3 侧载分发说明齐全。**
