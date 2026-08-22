import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/sandbox/proot_provider.dart' as proot;
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault/sandbox/wsl_process_config.dart';
import 'package:vault/sandbox/wsl_provider.dart' as wsl;

void main() {
  test('provider entrypoints keep exporting workspace API', () {
    _acceptsWorkspaceType<wsl.WslWorkspace>();
    _acceptsWorkspaceType<proot.ProotWorkspace>();

    expect(wsl.WslWorkspace.new, isA<Function>());
    expect(proot.ProotWorkspace.new, isA<Function>());
  });

  test('providers delegate interactive handles to partitioned workspaces', () {
    final wslProvider = File(
      'lib/sandbox/wsl_provider.dart',
    ).readAsStringSync();
    final prootProvider = File(
      'lib/sandbox/proot_provider.dart',
    ).readAsStringSync();
    final wslWorkspace = File(
      'lib/sandbox/wsl_workspace.dart',
    ).readAsStringSync();
    final prootWorkspace = File(
      'lib/sandbox/proot_workspace.dart',
    ).readAsStringSync();

    expect(wslProvider, isNot(contains('class WslWorkspace')));
    expect(prootProvider, isNot(contains('class ProotWorkspace')));
    expect(wslProvider, contains('return WslWorkspace('));
    expect(prootProvider, contains('final workspace = ProotWorkspace('));
    expect(wslProvider, contains('wslHostEnvironment'));
    expect(wslWorkspace, contains('wslHostEnvironment'));
    expect(
      wslWorkspace,
      contains('class WslWorkspace implements SandboxWorkspace'),
    );
    expect(
      prootWorkspace,
      contains('class ProotWorkspace implements SandboxWorkspace'),
    );
  });

  test('WSL provider and workspace share minimal host process semantics', () {
    expect(wslHostEnvironment, {
      'PATH': r'C:\Windows\System32;C:\Windows',
      'SystemRoot': r'C:\Windows',
      'WINDIR': r'C:\Windows',
    });
  });
}

void _acceptsWorkspaceType<T extends SandboxWorkspace>() {}
