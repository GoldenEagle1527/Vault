import 'package:vault/offload/offload_protocol.dart';

/// Host-side implementation for one `vault-*` CLI family.
abstract class OffloadHandler {
  /// Registry permission id (e.g. `clipboard`).
  String get permissionId;

  /// Guest CLI basename (e.g. `vault-clipboard`).
  String get command;

  Future<OffloadResponse> handle(OffloadRequest request);
}
