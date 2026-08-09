import 'dart:convert';
import 'dart:io';

import 'package:vault/offload/handlers/offload_handler.dart';
import 'package:vault/offload/offload_protocol.dart';

/// `vault-device` — non-sensitive host metadata.
class DeviceInfoHandler implements OffloadHandler {
  @override
  String get permissionId => 'device_info';

  @override
  String get command => 'vault-device';

  @override
  Future<OffloadResponse> handle(OffloadRequest request) async {
    final args = request.args;
    final sub = args.isEmpty ? 'info' : args.first;

    switch (sub) {
      case 'smoke':
        return OffloadResponse.ok('ok device ${Platform.operatingSystem}');

      case 'info':
        final info = <String, dynamic>{
          'platform': Platform.operatingSystem,
          'version': Platform.operatingSystemVersion,
          'locale': Platform.localeName,
          'numberOfProcessors': Platform.numberOfProcessors,
          'localHostname': Platform.localHostname,
          'executable': Platform.resolvedExecutable,
          'environment': {
            'PROCESSOR_ARCHITECTURE':
                Platform.environment['PROCESSOR_ARCHITECTURE'],
            'PROCESSOR_IDENTIFIER':
                Platform.environment['PROCESSOR_IDENTIFIER'],
          },
        };
        return OffloadResponse.ok(
          const JsonEncoder.withIndent('  ').convert(info),
        );

      default:
        return OffloadResponse.error(
          2,
          'usage: vault-device info|smoke',
        );
    }
  }
}
