import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_highlight/themes/vs2015.dart';
import 'package:highlight/highlight.dart' show highlight, Node;

/// Map a guest file path / basename to a highlight.js language id.
///
/// Returns null when the extension is unknown (plain monospace preview).
String? highlightLanguageForPath(String guestPath) {
  final base = guestPath.replaceAll('\\', '/').split('/').last.toLowerCase();
  if (base.isEmpty) return null;

  switch (base) {
    case 'dockerfile':
      return 'dockerfile';
    case 'makefile':
    case 'gnumakefile':
      return 'makefile';
    case 'cmakelists.txt':
      return 'cmake';
    case 'gemfile':
    case 'rakefile':
      return 'ruby';
  }

  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return null;
  final ext = base.substring(dot + 1);

  const byExt = <String, String>{
    'dart': 'dart',
    'py': 'python',
    'pyw': 'python',
    'js': 'javascript',
    'mjs': 'javascript',
    'cjs': 'javascript',
    'jsx': 'javascript',
    'ts': 'typescript',
    'tsx': 'typescript',
    'json': 'json',
    'jsonc': 'json',
    'md': 'markdown',
    'markdown': 'markdown',
    'sh': 'bash',
    'bash': 'bash',
    'zsh': 'bash',
    'fish': 'bash',
    'yaml': 'yaml',
    'yml': 'yaml',
    'html': 'xml',
    'htm': 'xml',
    'xhtml': 'xml',
    'xml': 'xml',
    'svg': 'xml',
    'vue': 'xml',
    'css': 'css',
    'scss': 'scss',
    'less': 'less',
    'c': 'c',
    'h': 'c',
    'cpp': 'cpp',
    'cc': 'cpp',
    'cxx': 'cpp',
    'hpp': 'cpp',
    'hh': 'cpp',
    'java': 'java',
    'kt': 'kotlin',
    'kts': 'kotlin',
    'go': 'go',
    'rs': 'rust',
    'rb': 'ruby',
    'php': 'php',
    'swift': 'swift',
    'sql': 'sql',
    'toml': 'ini',
    'ini': 'ini',
    'cfg': 'ini',
    'conf': 'ini',
    'properties': 'properties',
    'gradle': 'gradle',
    'cmake': 'cmake',
    'lua': 'lua',
    'r': 'r',
    'pl': 'perl',
    'pm': 'perl',
    'cs': 'cs',
    'fs': 'fsharp',
    'graphql': 'graphql',
    'gql': 'graphql',
    'proto': 'protobuf',
    'diff': 'diff',
    'patch': 'diff',
    'dockerfile': 'dockerfile',
    'mk': 'makefile',
    'makefile': 'makefile',
  };
  return byExt[ext];
}

/// Theme map for [HighlightView] / [SelectableHighlightView].
Map<String, TextStyle> highlightThemeForBrightness(Brightness brightness) {
  return brightness == Brightness.dark ? vs2015Theme : githubTheme;
}

/// Selectable syntax-highlighted code (preview mode).
class SelectableHighlightView extends StatelessWidget {
  const SelectableHighlightView({
    super.key,
    required this.source,
    this.language,
    required this.theme,
    this.padding = const EdgeInsets.all(16),
    this.textStyle,
  });

  final String source;
  final String? language;
  final Map<String, TextStyle> theme;
  final EdgeInsetsGeometry padding;
  final TextStyle? textStyle;

  static const _rootKey = 'root';

  List<TextSpan> _convert(List<Node> nodes) {
    final spans = <TextSpan>[];
    var current = spans;
    final stack = <List<TextSpan>>[];

    void traverse(Node node) {
      if (node.value != null) {
        current.add(
          node.className == null
              ? TextSpan(text: node.value)
              : TextSpan(text: node.value, style: theme[node.className!]),
        );
      } else if (node.children != null) {
        final tmp = <TextSpan>[];
        current.add(TextSpan(children: tmp, style: theme[node.className!]));
        stack.add(current);
        current = tmp;
        for (final n in node.children!) {
          traverse(n);
        }
        current = stack.isEmpty ? spans : stack.removeLast();
      }
    }

    for (final node in nodes) {
      traverse(node);
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final root = theme[_rootKey];
    var style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.45,
      color: root?.color ?? const Color(0xff000000),
    );
    if (textStyle != null) {
      style = style.merge(textStyle);
    }

    final nodes = highlight.parse(source, language: language).nodes ?? const [];
    final bg = root?.backgroundColor ?? const Color(0xffffffff);

    // ColoredBox sizes to its child; without expand, short files only paint a
    // small code block (looks like "half the screen").
    return SizedBox.expand(
      child: ColoredBox(
        color: bg,
        child: SingleChildScrollView(
          padding: padding,
          child: SizedBox(
            width: double.infinity,
            child: SelectableText.rich(
              TextSpan(style: style, children: _convert(nodes)),
            ),
          ),
        ),
      ),
    );
  }
}
