import 'package:flutter_test/flutter_test.dart';
import 'package:vault/sandbox/alpine_mirrors.dart';

void main() {
  group('rewriteAlpineApkRepositories', () {
    test('rewrites official CDN to Aliyun while keeping version paths', () {
      const input = '''
https://dl-cdn.alpinelinux.org/alpine/v3.21/main
https://dl-cdn.alpinelinux.org/alpine/v3.21/community
''';
      final out = rewriteAlpineApkRepositories(input);
      expect(
        out,
        '''
https://mirrors.aliyun.com/alpine/v3.21/main
https://mirrors.aliyun.com/alpine/v3.21/community
''',
      );
      expect(alpineRepositoriesNeedMirror(out), isFalse);
    });

    test('rewrites numbered dl-N mirrors and http', () {
      const input = '''
http://dl-2.alpinelinux.org/alpine/v3.23/main
https://dl-5.alpinelinux.org/alpine/edge/community
''';
      final out = rewriteAlpineApkRepositories(
        input,
        mirror: 'https://mirrors.tuna.tsinghua.edu.cn/alpine/',
      );
      expect(
        out,
        '''
https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.23/main
https://mirrors.tuna.tsinghua.edu.cn/alpine/edge/community
''',
      );
    });

    test('is a no-op when already on a China mirror', () {
      const input = '''
https://mirrors.aliyun.com/alpine/v3.21/main
https://mirrors.aliyun.com/alpine/v3.21/community
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
    test('installs default packages including git', () {
      final script = alpineApkInstallPackagesShellScript();
      expect(script, 'apk update && apk add --no-cache git');
      expect(kDefaultAlpinePackages, contains('git'));
    });

    test('rejects shell-unsafe package names', () {
      expect(
        () => alpineApkInstallPackagesShellScript(packages: ['git;rm']),
        throwsArgumentError,
      );
    });
  });
}
