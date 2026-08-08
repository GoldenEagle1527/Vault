import 'package:vault/sandbox/sandbox_provider.dart';

/// Android proot 后端。M2/M3 设备验证通过后再替换此占位实现。
class ProotProvider implements SandboxProvider {
  @override
  Future<SandboxCapabilities> probe() async {
    return const SandboxCapabilities(
      available: false,
      backend: SandboxBackend.proot,
      architecture: 'aarch64',
      hint:
          'Android proot 后端尚未接入。请先完成 M2 设备验证'
          '（targetSdk 35 下的 libproot.so + PROOT_LOADER）。',
      notes: [
        '需要将打过补丁的 proot 放入 jniLibs（不能放 assets/）。',
        'rootfs 必须按 16KB 页对齐（使用 proot-distro 的 Alpine，而非上游官方包）。',
      ],
    );
  }

  @override
  Future<SandboxSession> create(String sessionId) {
    throw UnsupportedError('ProotProvider.create 尚未实现。');
  }

  @override
  Future<SandboxSession> attach(String sessionId) {
    throw UnsupportedError('ProotProvider.attach 尚未实现。');
  }

  @override
  Future<void> destroy(String sessionId) {
    throw UnsupportedError('ProotProvider.destroy 尚未实现。');
  }

  @override
  Future<List<SandboxInfo>> list() async => const [];
}
