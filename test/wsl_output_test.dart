import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault/sandbox/wsl_output.dart';

List<int> _utf16Le(String text, {bool bom = false}) {
  final bytes = <int>[if (bom) ...[0xFF, 0xFE]];
  for (final unit in text.codeUnits) {
    bytes.add(unit & 0xFF);
    bytes.add((unit >> 8) & 0xFF);
  }
  return bytes;
}

void main() {
  test('解码中文 Windows 下 WSL 的 UTF-16LE 输出', () {
    const text = '操作成功';
    final utf16 = _utf16Le(text);
    expect(() => utf8.decode(utf16), throwsFormatException);
    expect(decodeWslOutput(utf16), text);
  });

  test('解码 UTF-8 客户机输出', () {
    expect(
      decodeWslOutput(utf8.encode('hello-from-vault\n')),
      'hello-from-vault\n',
    );
  });

  test('解码带 BOM 的 UTF-16LE', () {
    expect(decodeWslOutput(_utf16Le('Ubuntu', bom: true)), 'Ubuntu');
  });
}
