import 'package:flutter/material.dart';

enum FileBrowserOperation {
  open,
  rename,
  copy,
  cut,
  paste,
  delete,
  export,
  share,
  pack,
  selectAll,
  clear,
}

List<PopupMenuEntry<FileBrowserOperation>> buildFileBrowserOperationItems({
  required bool hasSingleSelection,
  required bool hasSelection,
  required bool canPaste,
  required bool hasEntries,
}) {
  return [
    if (hasSingleSelection)
      const PopupMenuItem(value: FileBrowserOperation.open, child: Text('打开')),
    if (hasSingleSelection)
      const PopupMenuItem(
        value: FileBrowserOperation.rename,
        child: Text('重命名'),
      ),
    if (hasSelection)
      const PopupMenuItem(value: FileBrowserOperation.copy, child: Text('复制')),
    if (hasSelection)
      const PopupMenuItem(value: FileBrowserOperation.cut, child: Text('剪切')),
    if (canPaste)
      const PopupMenuItem(value: FileBrowserOperation.paste, child: Text('粘贴')),
    if (hasSelection)
      const PopupMenuItem(
        value: FileBrowserOperation.delete,
        child: Text('删除'),
      ),
    if (hasSelection)
      const PopupMenuItem(
        value: FileBrowserOperation.export,
        child: Text('另存为'),
      ),
    if (hasSelection)
      const PopupMenuItem(value: FileBrowserOperation.share, child: Text('分享')),
    if (hasSelection)
      const PopupMenuItem(
        value: FileBrowserOperation.pack,
        child: Text('打包'),
      ),
    if (hasEntries)
      const PopupMenuItem(
        value: FileBrowserOperation.selectAll,
        child: Text('全选'),
      ),
    if (hasSelection)
      const PopupMenuItem(
        value: FileBrowserOperation.clear,
        child: Text('取消选择'),
      ),
  ];
}
