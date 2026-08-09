import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/sandbox/alpine_mirrors.dart';

void main() {
  group('rewriteAlpineApkRepositories', () {
    test('rewrites official CDN to Tsinghua while keeping version paths', () {
      const input = '''
https://dl-cdn.alpinelinux.org/alpine/v3.21/main
https://dl-cdn.alpinelinux.org/alpine/v3.21/community
''';
      final out = rewriteAlpineApkRepositories(input);
      expect(
        out,
        '''
https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/main
https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/community
''',
      );
      expect(alpineRepositoriesNeedMirror(out), isFalse);
    });

    test('rewrites Aliyun and numbered dl-N hosts to the default mirror', () {
      const input = '''
https://mirrors.aliyun.com/alpine/v3.23/main
http://dl-2.alpinelinux.org/alpine/edge/community
''';
      final out = rewriteAlpineApkRepositories(input);
      expect(
        out,
        '''
https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.23/main
https://mirrors.tuna.tsinghua.edu.cn/alpine/edge/community
''',
      );
    });

    test('is a no-op when already on the default mirror', () {
      const input = '''
https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/main
https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/community
''';
      expect(rewriteAlpineApkRepositories(input), input);
      expect(alpineRepositoriesNeedMirror(input), isFalse);
    });
  });

  test('alpineApkMirrorShellScript embeds the default mirror', () {
    final script = alpineApkMirrorShellScript();
    expect(script, contains(kDefaultAlpineApkMirror));
    expect(script, contains('/etc/apk/repositories'));
    expect(script, contains('sed -i'));
  });

  group('alpineApkInstallPackagesShellScript', () {
    test('installs default packages including git, python3, py3-pip', () {
      final script = alpineApkInstallPackagesShellScript();
      expect(script, contains('apk add --no-cache git python3 py3-pip'));
      expect(script, contains(kDefaultPipIndexUrl));
      expect(script, contains('/etc/pip.conf'));
      expect(kDefaultAlpinePackages, ['git', 'python3', 'py3-pip']);
    });

    test('rejects shell-unsafe package names', () {
      expect(
        () => alpineApkInstallPackagesShellScript(packages: ['git;rm']),
        throwsArgumentError,
      );
    });
  });

  group('alpine pip mirror', () {
    test('alpinePipConfContent points at Tsinghua', () {
      final conf = alpinePipConfContent();
      expect(conf, contains('index-url = $kDefaultPipIndexUrl'));
      expect(conf, contains('trusted-host = $kDefaultPipTrustedHost'));
    });

    test('applyAlpinePipConfOnHost writes /etc/pip.conf', () async {
      final dir = await Directory.systemTemp.createTemp('vault_pip_');
      addTearDown(() => dir.delete(recursive: true));

      await applyAlpinePipConfOnHost(dir.path);

      final conf = await File(p.join(dir.path, 'etc', 'pip.conf')).readAsString();
      expect(conf, alpinePipConfContent());
    });
  });

  group('applyAlpineResolvConfOnHost', () {
    test('overwrites existing 1.1.1.1 with China nameservers', () async {
      final dir = await Directory.systemTemp.createTemp('vault_resolv_');
      addTearDown(() => dir.delete(recursive: true));
      final resolv = File(p.join(dir.path, 'etc', 'resolv.conf'));
      await resolv.parent.create(recursive: true);
      await resolv.writeAsString('nameserver 1.1.1.1\n');

      await applyAlpineResolvConfOnHost(dir.path);

      expect(
        await resolv.readAsString(),
        'nameserver 223.5.5.5\nnameserver 119.29.29.29\n',
      );
    });
  });
}
