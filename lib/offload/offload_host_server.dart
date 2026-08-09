import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vault/offload/handlers/calendar_handler.dart';
import 'package:vault/offload/handlers/clipboard_handler.dart';
import 'package:vault/offload/handlers/config_handler.dart';
import 'package:vault/offload/handlers/contacts_handler.dart';
import 'package:vault/offload/handlers/device_info_handler.dart';
import 'package:vault/offload/handlers/host_files_handler.dart';
import 'package:vault/offload/handlers/location_handler.dart';
import 'package:vault/offload/handlers/notification_handler.dart';
import 'package:vault/offload/handlers/offload_handler.dart';
import 'package:vault/offload/handlers/open_url_handler.dart';
import 'package:vault/offload/handlers/photos_handler.dart';
import 'package:vault/offload/handlers/speak_handler.dart';
import 'package:vault/offload/handlers/speech_handler.dart';
import 'package:vault/offload/offload_gate.dart';
import 'package:vault/offload/offload_protocol.dart';

/// Host-side TCP/HTTP offload bridge for Windows (and reusable on desktop).
///
/// Listens on `127.0.0.1:<ephemeral>` via [HttpServer]. WSL2 guests reach this
/// through localhost forwarding (default) using `/etc/vault-offload.host` +
/// `/etc/vault-offload.port`. See [docs in wsl_offload_install.dart].
class OffloadHostServer {
  OffloadHostServer({
    Map<String, OffloadHandler>? handlers,
    OffloadNotificationCallback? onNotification,
  }) : _handlers = handlers ?? _defaultHandlers(onNotification);

  final Map<String, OffloadHandler> _handlers;
  HttpServer? _server;
  int? _port;

  int? get port => _port;
  bool get isRunning => _server != null;

  static Map<String, OffloadHandler> _defaultHandlers(
    OffloadNotificationCallback? onNotification,
  ) {
    final notification = NotificationHandler(onNotify: onNotification);
    final list = <OffloadHandler>[
      ClipboardHandler(),
      DeviceInfoHandler(),
      OpenUrlHandler(),
      notification,
      CalendarHandler(),
      ContactsHandler(),
      PhotosHandler(),
      LocationHandler(),
      HostFilesHandler(),
      ConfigHandler(),
      SpeakHandler(),
      SpeechHandler(),
    ];
    return {for (final h in list) h.command: h};
  }

  /// Singleton used by app init / WslProvider.
  static OffloadHostServer? instance;

  /// Start listening on loopback. Idempotent.
  Future<int> start({InternetAddress? address, int port = 0}) async {
    if (_server != null && _port != null) return _port!;

    final bindAddr = address ?? InternetAddress.loopbackIPv4;
    final server = await HttpServer.bind(bindAddr, port);
    _server = server;
    _port = server.port;
    instance = this;

    server.listen(_handleHttp, onError: (Object e, StackTrace st) {
      stderr.writeln('OffloadHostServer listen error: $e\n$st');
    });

    return _port!;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _port = null;
    if (identical(instance, this)) instance = null;
    await server?.close(force: true);
  }

  Future<void> _handleHttp(HttpRequest req) async {
    try {
      if (req.method != 'POST') {
        await _writeJson(
          req,
          OffloadResponse.error(2, 'POST required'),
          HttpStatus.methodNotAllowed,
        );
        return;
      }

      final body = await utf8.decoder.bind(req).join();
      final OffloadRequest request;
      try {
        request = OffloadRequest.decode(body.isEmpty ? '{}' : body);
      } catch (e) {
        await _writeJson(
          req,
          OffloadResponse.error(2, 'invalid json: $e'),
          HttpStatus.badRequest,
        );
        return;
      }

      final response = await dispatch(request);
      await _writeJson(req, response, HttpStatus.ok);
    } catch (e, st) {
      stderr.writeln('OffloadHostServer request error: $e\n$st');
      try {
        await _writeJson(
          req,
          OffloadResponse.error(1, 'internal error: $e'),
          HttpStatus.internalServerError,
        );
      } catch (_) {}
    }
  }

  Future<void> _writeJson(
    HttpRequest req,
    OffloadResponse response,
    int status,
  ) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.headers.set('X-Vault-Exit-Code', '${response.exitCode}');
    // Raw mode: body is stdout only (easier for Alpine shell stubs).
    final accept = req.headers.value(HttpHeaders.acceptHeader) ?? '';
    final raw = req.uri.queryParameters['raw'] == '1' ||
        accept.contains('application/vnd.vault.raw');
    if (raw) {
      req.response.headers.contentType =
          ContentType('text', 'plain', charset: 'utf-8');
      req.response.write(response.stdout);
    } else {
      req.response.write(response.encode());
    }
    await req.response.close();
  }

  /// Dispatch one request (also useful for unit tests).
  Future<OffloadResponse> dispatch(OffloadRequest request) async {
    final command = request.command;
    if (command.isEmpty) {
      return OffloadResponse.unknownCommand('missing argv[0]');
    }

    // Wave4 integrations are Android-only (Windows → 125, not 126).
    if (command == 'vault-a11y' || command == 'vault-shizuku') {
      return OffloadResponse.unsupported(
        'unsupported_platform: $command is Android-only (Wave4)',
      );
    }

    final gated = await OffloadGate.check(
      command: command,
      sessionId: request.effectiveSessionId,
    );
    if (gated != null) return gated;

    final handler = _handlers[command];
    if (handler == null) {
      return OffloadResponse.unknownCommand('unknown_command: $command');
    }

    try {
      return await handler.handle(request);
    } catch (e) {
      return OffloadResponse.error(1, 'handler error: $e');
    }
  }
}

/// Ensure the process-wide server is running; return its port.
Future<int> ensureOffloadHostServer({
  OffloadNotificationCallback? onNotification,
}) async {
  final existing = OffloadHostServer.instance;
  if (existing != null && existing.isRunning && existing.port != null) {
    return existing.port!;
  }
  final server = OffloadHostServer(onNotification: onNotification);
  return server.start();
}
