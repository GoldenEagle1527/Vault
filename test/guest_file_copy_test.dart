import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vault/sandbox/guest_file_copy.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vault_file_copy_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Uint8List patternedBytes(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = i & 0xff;
    }
    return bytes;
  }

  test('streamCopyHostFile copies multi-chunk payload', () async {
    final payload = patternedBytes(200 * 1024);
    final src = File(p.join(tmp.path, 'src.bin'));
    final dest = File(p.join(tmp.path, 'nested', 'dest.bin'));
    await src.writeAsBytes(payload, flush: true);

    await streamCopyHostFile(sourcePath: src.path, destPath: dest.path);

    expect(await dest.readAsBytes(), payload);
  });

  test('streamCopyHostFile copies empty file', () async {
    final src = File(p.join(tmp.path, 'empty.bin'));
    final dest = File(p.join(tmp.path, 'out.bin'));
    await src.writeAsBytes(const [], flush: true);

    await streamCopyHostFile(sourcePath: src.path, destPath: dest.path);

    expect(await dest.length(), 0);
  });

  test('streamCopyHostFile rejects missing source', () async {
    await expectLater(
      streamCopyHostFile(
        sourcePath: p.join(tmp.path, 'missing.bin'),
        destPath: p.join(tmp.path, 'out.bin'),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('streamCopyHostFileToSink pipes onto an IOSink', () async {
    final payload = patternedBytes(80 * 1024);
    final src = File(p.join(tmp.path, 'src.bin'));
    final dest = File(p.join(tmp.path, 'via-sink.bin'));
    await src.writeAsBytes(payload, flush: true);

    await streamCopyHostFileToSink(
      sourcePath: src.path,
      sink: dest.openWrite(),
    );

    expect(await dest.readAsBytes(), payload);
  });
}
