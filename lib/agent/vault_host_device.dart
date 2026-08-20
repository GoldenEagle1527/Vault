import 'dart:io' show Platform;

/// Where the user runs the Vault app (not the Alpine guest).
enum VaultHostDevice {
  /// Android phone / tablet.
  mobile,

  /// Windows PC.
  desktop;

  static VaultHostDevice current() {
    if (Platform.isAndroid) return VaultHostDevice.mobile;
    if (Platform.isWindows) return VaultHostDevice.desktop;
    throw UnsupportedError(
      'Vault host device is only supported on Android and Windows '
      '(got ${Platform.operatingSystem}).',
    );
  }

  /// User-facing label in Chinese.
  String get labelZh => switch (this) {
    VaultHostDevice.mobile => '手机',
    VaultHostDevice.desktop => '电脑',
  };

  String get platformName => switch (this) {
    VaultHostDevice.mobile => 'Android',
    VaultHostDevice.desktop => 'Windows',
  };

  String get sandboxBackendLabel => switch (this) {
    VaultHostDevice.mobile => 'proot（Android 内嵌 Alpine）',
    VaultHostDevice.desktop => 'WSL2（Windows 内嵌 Alpine）',
  };

  String get networkStackHint => switch (this) {
    VaultHostDevice.mobile =>
      '沙箱与手机共享网络栈：出站 curl/apk 与在 127.0.0.1 上 listen 通常可用（非“断网沙箱”）',
    VaultHostDevice.desktop =>
      '沙箱经 WSL2 与 Windows 主机共享网络：出站 curl/apk 与在 127.0.0.1 上 listen 通常可用',
  };

  String get uiInteractionHint => switch (this) {
    VaultHostDevice.mobile =>
      '用户通过触屏操作 App；侧栏、附件、站点启动等均为移动端交互；做网页时可优先考虑手机 viewport',
    VaultHostDevice.desktop =>
      '用户通过键盘鼠标操作 App；聊天框 Enter 发送、Shift+Enter 换行；做网页时可兼顾桌面布局',
  };
}
