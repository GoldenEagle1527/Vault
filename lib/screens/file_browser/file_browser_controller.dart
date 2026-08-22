import 'package:flutter/foundation.dart';
import 'package:vault/sandbox/sandbox_provider.dart';

/// Owns file-browser navigation and selection state.
class FileBrowserController extends ChangeNotifier {
  FileBrowserController({
    String initialPath = kGuestHome,
    String? projectGuestPath,
  }) : _currentPath = assertGuestPathUnderHome(initialPath),
       _projectPath = _normalizeOptionalPath(projectGuestPath);

  String _currentPath;
  final String? _projectPath;
  final Set<String> _selected = <String>{};

  String get currentPath => _currentPath;
  String? get projectPath => _projectPath;
  Set<String> get selected => Set.unmodifiable(_selected);
  bool get canGoUp =>
      _currentPath != kGuestHome && _currentPath.startsWith('$kGuestHome/');
  String get pathLabel => _currentPath == kGuestHome ? '/root' : _currentPath;

  void openPath(String path) {
    final normalized = assertGuestPathUnderHome(path);
    if (_currentPath == normalized && _selected.isEmpty) return;
    _currentPath = normalized;
    _selected.clear();
    notifyListeners();
  }

  bool goUp() {
    if (!canGoUp) return false;
    final parent = _currentPath.substring(0, _currentPath.lastIndexOf('/'));
    openPath(parent.isEmpty || parent == '/' ? kGuestHome : parent);
    return true;
  }

  bool jumpToProject() {
    final project = _projectPath;
    if (project == null) return false;
    openPath(project);
    return true;
  }

  void toggleSelection(String path) {
    if (_selected.contains(path)) {
      _selected.remove(path);
    } else {
      _selected.add(path);
    }
    notifyListeners();
  }

  void selectOnly(String path) {
    if (_selected.length == 1 && _selected.contains(path)) return;
    _selected
      ..clear()
      ..add(path);
    notifyListeners();
  }

  void selectAll(Iterable<String> paths) {
    _selected
      ..clear()
      ..addAll(paths);
    notifyListeners();
  }

  void clearSelection() {
    if (_selected.isEmpty) return;
    _selected.clear();
    notifyListeners();
  }

  void replaceSelection(String path) {
    _selected
      ..clear()
      ..add(path);
    notifyListeners();
  }

  static String? _normalizeOptionalPath(String? path) {
    if (path == null || path.isEmpty) return null;
    try {
      return assertGuestPathUnderHome(path);
    } catch (_) {
      return null;
    }
  }
}
