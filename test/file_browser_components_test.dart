import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault/sandbox/guest_media_source.dart';
import 'package:vault/screens/file_browser/file_browser_operation_menu.dart';
import 'package:vault/screens/file_browser/file_browser_path_navigation.dart';
import 'package:vault/screens/file_browser_screen.dart';
import 'package:vault/widgets/guest_media_preview.dart';

void main() {
  group('FileBrowserController', () {
    test('normalizes navigation and exposes root label', () {
      final controller = FileBrowserController(
        initialPath: '/root/projects/demo',
        projectGuestPath: '/root/projects/current',
      );
      addTearDown(controller.dispose);

      expect(controller.pathLabel, '/root/projects/demo');
      expect(controller.canGoUp, isTrue);
      expect(controller.goUp(), isTrue);
      expect(controller.currentPath, '/root/projects');
      expect(controller.jumpToProject(), isTrue);
      expect(controller.currentPath, '/root/projects/current');

      controller.openPath('/root');
      expect(controller.pathLabel, '/root');
      expect(controller.canGoUp, isFalse);
      expect(controller.goUp(), isFalse);
    });

    test('rejects escaped paths and ignores invalid project shortcut', () {
      expect(
        () => FileBrowserController(initialPath: '/etc'),
        throwsArgumentError,
      );
      final controller = FileBrowserController(projectGuestPath: '/etc');
      addTearDown(controller.dispose);
      expect(controller.projectPath, isNull);
      expect(controller.jumpToProject(), isFalse);
    });

    test('owns selection transitions', () {
      final controller = FileBrowserController();
      addTearDown(controller.dispose);

      controller.toggleSelection('/root/a');
      controller.toggleSelection('/root/b');
      expect(controller.selected, {'/root/a', '/root/b'});
      controller.toggleSelection('/root/a');
      expect(controller.selected, {'/root/b'});
      controller.selectOnly('/root/c');
      expect(controller.selected, {'/root/c'});
      controller.selectAll(['/root/a', '/root/b']);
      expect(controller.selected, {'/root/a', '/root/b'});
      controller.clearSelection();
      expect(controller.selected, isEmpty);
    });
  });

  testWidgets('path navigation preserves labels and up action', (tester) async {
    var upCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FileBrowserPathNavigation(
            pathLabel: '/root/projects/demo',
            canGoUp: true,
            enabled: true,
            dropEnabled: true,
            onGoUp: () => upCount++,
          ),
        ),
      ),
    );

    expect(find.text('/root/projects/demo'), findsOneWidget);
    expect(find.text('可拖拽导入'), findsOneWidget);
    await tester.tap(find.byTooltip('上一级'));
    expect(upCount, 1);
  });

  test('operation menu only includes available actions', () {
    final items = buildFileBrowserOperationItems(
      hasSingleSelection: false,
      hasSelection: false,
      canPaste: true,
      hasEntries: true,
    );
    final values = items
        .whereType<PopupMenuItem<FileBrowserOperation>>()
        .map((item) => item.value)
        .toSet();

    expect(values, {
      FileBrowserOperation.paste,
      FileBrowserOperation.selectAll,
    });
  });

  testWidgets('media facade still exposes image preview', (tester) async {
    final source = GuestMediaSource.hostFile(
      File('unused.png'),
      bytes: Uint8List.fromList(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4'
          'nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: GuestImagePreview(source: source)),
    );

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });
}
