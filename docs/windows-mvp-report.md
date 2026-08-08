# Vault Windows MVP 报告

**状态：** 已验收通过  
**日期：** 2026-08-08  
**平台：** Windows 10/11 + WSL2 + Flutter 3.41.9  
**许可：** GPLv3  

---

## 1. 目标与范围

为每个 Agent 会话提供**独立的 Linux 沙箱**，Windows 端采用「一会话一 WSL2 发行版」：

| 能力 | MVP 结果 |
|------|----------|
| 创建 / 附着 / 删除会话 | ✅ |
| 交互终端（PTY + xterm） | ✅ |
| Alpine + `apk` | ✅ |
| 默认不挂载 Windows 盘符 | ✅ |
| 会话间文件系统 / 软件包隔离 | ✅ |
| 中文 UI | ✅ |
| Android 沙箱 | ❌ 未开始（见 `android-mvp-plan.md`） |
| Agent 编排层 | ❌ 未开始 |

---

## 2. 交付物

```
lib/sandbox/
  sandbox_models.dart      # SandboxCapabilities / Session / CommandResult
  sandbox_provider.dart    # 抽象 + createSandboxProvider()
  wsl_provider.dart        # Windows 实现
  wsl_output.dart          # wsl.exe UTF-16LE/UTF-8 解码
  proot_provider.dart      # Android 占位（不可用）
lib/screens/               # 首页、终端页（中文）
lib/widgets/session_terminal.dart
assets/rootfs/
  alpine-minirootfs-x86_64.tar.gz
  alpine-minirootfs-aarch64.tar.gz
LICENSE / THIRD_PARTY_LICENSES.md
```

**关键接口（勿泄漏 `dart:io Process`）：**

- `SandboxProvider.probe / create / attach / destroy / list`
- `SandboxSession.output / write / resize / exitCode / run`

**运行：**

```bash
flutter run -d windows
```

---

## 3. 架构（Windows）

```
Flutter UI（会话列表 + xterm）
        │
        ▼
   WslProvider
        │
        ├── wsl --import vault_<id> <dir> alpine.tar.gz --version 2
        ├── 写入 /etc/wsl.conf（硬化）
        ├── flutter_pty → wsl.exe -d vault_<id> -u root --cd /root -e /bin/sh -l
        └── wsl --unregister vault_<id>
```

发行版命名：`vault_<sessionId>`。元数据：`ApplicationSupport/wsl_distros/sessions.json`。

---

## 4. 验收记录

在会话终端内验证通过：

1. `uname -a` / `id` / `pwd` → Linux Alpine、root、`/root`
2. `apk update && apk add curl` → 可用
3. `ls /mnt`、`ls /c` → 无 Windows 盘符
4. 双会话：A 写 `/root/mark.txt`，B 不可见；B `apk add` 不影响 A
5. 删除会话 → `wsl -l -v` 中对应发行版消失
6. （可选）`htop` 全屏与 Ctrl+C 正常

**已知非阻塞提示：**  
`wsl: 检测到 localhost 代理配置，但未镜像到 WSL…` —— NAT 模式下系统代理无法直接进 WSL，可忽略，或在 `%UserProfile%\.wslconfig` 设 `networkingMode=mirrored`。

**隔离边界（需在产品说明中诚实告知）：**

- 磁盘：每会话一份 `ext4.vhdx`，实际常接近 ~1 GB（不是 5–10 MB）
- 安全：文件系统与进程隔离；**共享**同一 WSL2 VM、内核、网络命名空间

---

## 5. 遇到的问题与解决方式

### 5.1 非空目录与 `flutter create`

**现象：** `flutter create .` 要求目录为空（或接近空）。  
**处理：** 计划文件放在仓库外 `~/.cursor/plans/`；本仓库初始化时本身为空，直接 `flutter create --platforms=android,windows`。  
**建议：** 新会话若目录已有文档，先挪到临时目录，create 完成后再移回。

### 5.2 新建会话：`FormatException: Missing extension byte (at offset 1)`

**原因：** 中文 Windows 上 `wsl.exe` 控制台输出多为 **UTF-16LE**（常无 BOM）。`Process.run(..., stdoutEncoding: utf8)` 会在解码阶段直接抛错。  
**表现：** import 其实已成功，Dart 侧先炸，留下孤儿发行版 `vault_*`。  
**解决：**

- 一律 `stdoutEncoding: null` / `stderrEncoding: null`，拿原始字节
- `decodeWslOutput()`：检测 BOM / UTF-16LE 启发式 / 失败则 UTF-8 `allowMalformed`
- 见 `lib/sandbox/wsl_output.dart`

**附带清理：** 失败后应用内删除，或 `wsl --unregister vault_<id>`。

### 5.3 进入终端即失败：`Wsl/Service/0x8007072c` + 代理提示

**现象：** 会话页能打开，终端打印 localhost 代理警告后 RPC 失败退出。  
**根因（组合拳）：**

1. 为隔离设置了 `[automount] enabled=false`
2. 宿主把**超长 Windows PATH** 传给 `wsl.exe`
3. WSL 仍默认 `appendWindowsPath=true`，尝试把每条 Windows 路径翻译进 Linux → 大量 `Failed to translate 'C:\...'`
4. 交互启动（尤其经 ConPTY / `flutter_pty`）在此状态下触发 `0x8007072c`（句柄类型不匹配）

代理提示本身**不是**致命错误。

**解决：**

1. `/etc/wsl.conf` 增加：

   ```ini
   [interop]
   enabled=true
   appendWindowsPath=false
   ```

2. 调用 `wsl.exe` 时使用精简环境（`includeParentEnvironment: false` + 短 `PATH`）
3. PTY 启动改为显式：

   ```text
   wsl.exe -d <name> -u root --cd /root -e /bin/sh -l
   ```

4. 写完 `wsl.conf` 后 `--terminate`，短暂等待再 attach，使配置生效  
5. 旧会话 attach 时 `_ensureHardened()`：若缺少 `appendWindowsPath=false` 则补写并 terminate

### 5.4 Git Bash 下手工测 WSL 的路径改写

**现象：** 在 Git Bash 里执行 `wsl -e /bin/sh` 时，`/bin/sh` 被改写成 `C:/Program Files/Git/usr/bin/sh`。  
**解决：** 测试脚本使用 `MSYS_NO_PATHCONV=1`，或改用 `cmd.exe` / PowerShell；**应用内 `Process.run('wsl.exe', …)` 无此问题**。

### 5.5 Alpine 来源与架构

**误区：** `wsl --install -d Alpine` —— Alpine 不在 `wsl --list --online`。  
**做法：** 打包 Alpine 3.21.3 minirootfs（x86_64 + aarch64），运行时按 `PROCESSOR_ARCHITECTURE` 选择，`wsl --import`。  
**脚本：** `scripts/prepare_windows_assets.sh`

### 5.6 依赖与包名勘误（相对最初调研稿）

| 原稿 | 实际 |
|------|------|
| `flutter_pty2` | 不存在 → 用 `flutter_pty` + `xterm` |
| OpenMinis 验证「Flutter+PRoot」 | OpenMinis 是 Kotlin/Compose，非 Flutter |
| 每发行版 5–10 MB | 实际 vhdx 常 ~1 GB 量级 |
| assets 里放 proot + chmod +x | Android 10+ / targetSdk≥29 不可行（留给 Android 计划） |

### 5.7 UI 语言

验收前将界面与 `probe()` 提示全部改为中文（首页、删除确认、能力卡片、错误关闭等）。

---

## 6. 关键配置摘要（会话内 `/etc/wsl.conf`）

```ini
[automount]
enabled=false
mountFsTab=false

[interop]
enabled=true
appendWindowsPath=false

[network]
generateResolvConf=true

[user]
default=root
```

---

## 7. 已知限制与后续（Windows）

| 项 | 说明 |
|----|------|
| 磁盘 | 差量 VHD / 共享 base image 未做（需管理员与 Lxss 注册表） |
| 网络隔离 | 未做；与系统其他 WSL 发行版共享网络 |
| 代理 | NAT 下 localhost 代理需 mirrored 模式或会话内自配 |
| Docker 后端 | 未做 |
| Agent 循环 / 文件浏览器 | M4，跨平台 |

---

## 8. 给后续 Agent 的指针

- Windows 实现以 `lib/sandbox/wsl_provider.dart` 为准，模式可复用到 Android 的 `ProotProvider`
- 终端接线以 `lib/widgets/session_terminal.dart` 为准（Android 上 `hardwareKeyboardOnly: false`）
- **下一步请严格按** [`android-mvp-plan.md`](./android-mvp-plan.md) **执行；M2 是硬门禁，未过关不要做 Android UI**
