import 'dart:convert';
import 'dart:math' as math;

/// Decode stdout/stderr from `wsl.exe`.
///
/// On Chinese Windows the WSL CLI commonly emits UTF-16LE (often without BOM).
/// Piped guest command output is usually UTF-8. Detect and decode accordingly.
String decodeWslOutput(List<int> bytes) {
  if (bytes.isEmpty) return '';

  var offset = 0;
  var forceUtf16 = false;
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    offset = 2;
    forceUtf16 = true;
  }

  final data = offset == 0 ? bytes : bytes.sublist(offset);
  if (data.isEmpty) return '';

  if (forceUtf16 || _looksLikeUtf16Le(data)) {
    final units = <int>[];
    for (var i = 0; i + 1 < data.length; i += 2) {
      units.add(data[i] | (data[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }

  return utf8.decode(bytes, allowMalformed: true);
}

bool _looksLikeUtf16Le(List<int> data) {
  if (data.length < 2 || data.length.isOdd) return false;

  final sample = math.min(data.length, 64);
  var zeroHigh = 0;
  final pairs = sample ~/ 2;
  for (var i = 0; i < pairs; i++) {
    if (data[i * 2 + 1] == 0) zeroHigh++;
  }
  // ASCII-heavy UTF-16LE has many zero high bytes.
  if (pairs > 0 && zeroHigh / pairs >= 0.4) return true;

  // Chinese-first UTF-16LE often fails strict UTF-8 at offset 1.
  try {
    utf8.decode(data);
    return false;
  } on FormatException {
    return true;
  }
}
