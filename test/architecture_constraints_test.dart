import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('known orchestration hotspots do not keep growing', () {
    final root = Directory.current.path;
    const hotspotLineCaps = <String, int>{
      'lib/screens/agent_screen.dart': 1200,
      'lib/screens/file_browser_screen.dart': 1000,
      'lib/agent/agent_service.dart': 1100,
      'packages/vault_agent_core/lib/src/agent/stateful_agent.dart': 1200,
    };

    for (final entry in hotspotLineCaps.entries) {
      final file = File(p.join(root, p.fromUri(entry.key)));
      expect(file.existsSync(), isTrue, reason: 'Missing hotspot ${entry.key}');
      final lines = file.readAsLinesSync().length;
      expect(
        lines,
        lessThanOrEqualTo(entry.value),
        reason:
            '${entry.key} grew to $lines lines (cap ${entry.value}). '
            'Extract orchestration before adding more behavior.',
      );
    }
  });

  test('new oversized orchestrators require an explicit baseline decision', () {
    final root = Directory.current.path;
    const knownHotspots = <String>{
      'lib/screens/agent_screen.dart',
      'lib/screens/file_browser_screen.dart',
      'lib/agent/agent_service.dart',
      'packages/vault_agent_core/lib/src/agent/stateful_agent.dart',
    };
    final oversized = <String>[];

    for (final relativeRoot in ['lib', 'packages/vault_agent_core/lib']) {
      final directory = Directory(p.join(root, relativeRoot));
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final relative = p
            .relative(entity.path, from: root)
            .replaceAll(r'\', '/');
        if (_isPlatformBridgeOrGenerated(relative)) continue;
        final source = entity.readAsStringSync();
        final lineCount = '\n'.allMatches(source).length + 1;
        if (lineCount <= 1200 || !_looksLikeOrchestrator(source)) continue;
        if (!knownHotspots.contains(relative)) {
          oversized.add('$relative ($lineCount lines)');
        }
      }
    }

    expect(
      oversized,
      isEmpty,
      reason:
          'New production orchestrators over 1200 lines are not allowed. '
          'DTOs, tests, examples, generated files, and platform bridges are '
          'excluded by scope/heuristic. Found: ${oversized.join(', ')}',
    );
  });
}

bool _isPlatformBridgeOrGenerated(String path) {
  return path.endsWith('.g.dart') ||
      path.endsWith('.mocks.dart') ||
      path.endsWith('_io.dart') ||
      path.endsWith('_web.dart') ||
      path.endsWith('_stub.dart');
}

bool _looksLikeOrchestrator(String source) {
  final asyncOperations = RegExp(
    r'\b(?:Future|Stream)<[^>]+>\s+[_a-zA-Z]\w*\s*\(',
  ).allMatches(source).length;
  final privateCommands = RegExp(
    r'\bvoid\s+_[a-zA-Z]\w*\s*\(',
  ).allMatches(source).length;
  final asyncBodies = RegExp(r'\basync\*?\s*\{').allMatches(source).length;
  return asyncOperations + privateCommands >= 12 && asyncBodies >= 8;
}
