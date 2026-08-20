import 'dart:convert';
import 'dart:typed_data';

import 'package:vault/agent/chat_attachment.dart';
import 'package:vault/agent/image_prepare.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault/sandbox/sandbox_models.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

/// Rehydrates image paths onto the **request copy** so history stays path-only.
class HydrateConversationImagesHook extends AgentHook {
  HydrateConversationImagesHook(this._readGuestFile);

  final Future<Uint8List?> Function(String guestPath) _readGuestFile;

  /// Request-only copy: adds [ImagePart]s. Does not mutate [messages].
  Future<List<LLMMessage>> hydrateMessages(List<LLMMessage> messages) async {
    final next = <LLMMessage>[];
    var changed = false;
    for (final message in messages) {
      if (message is UserMessage) {
        final hydrated = await _hydrateUser(message);
        changed = changed || !identical(hydrated, message);
        next.add(hydrated);
      } else if (message is FunctionExecutionResultMessage) {
        final hydrated = await _hydrateToolResults(message);
        changed = changed || !identical(hydrated, message);
        next.add(hydrated);
      } else {
        next.add(message);
      }
    }
    return changed ? next : messages;
  }

  @override
  Future<ModelCallHookResult> beforeModelCall(
    ModelCallHookContext context,
  ) async {
    final next = await hydrateMessages(context.request.requestMessages);
    if (identical(next, context.request.requestMessages)) {
      return ModelCallHookResult.proceed(request: context.request);
    }
    return ModelCallHookResult.proceed(
      request: context.request.copyWith(requestMessages: next),
      changed: true,
    );
  }

  Future<UserMessage> _hydrateUser(UserMessage message) async {
    final paths = <String>{
      ...ChatAttachmentMeta.listFromJson(
        message.metadata?['attachments'],
      ).where((a) => a.kind == GuestMediaKind.image).map((a) => a.guestPath),
      ..._imagePathsInText(
        message.contents.whereType<TextPart>().map((p) => p.text).join('\n'),
      ),
    };
    if (paths.isEmpty) return message;
    if (message.contents.any((p) => p is ImagePart)) return message;

    final contents = List<UserContentPart>.from(message.contents);
    for (final path in paths) {
      final part = await _imagePartForPath(path);
      if (part != null) contents.add(part);
    }
    if (contents.length == message.contents.length) return message;
    return UserMessage(
      contents,
      timestamp: message.timestamp,
      metadata: message.metadata,
    );
  }

  Future<FunctionExecutionResultMessage> _hydrateToolResults(
    FunctionExecutionResultMessage message,
  ) async {
    var changed = false;
    final results = <FunctionExecutionResult>[];
    for (final result in message.results) {
      final imagePath = result.metadata?['imagePath']?.toString();
      if (imagePath == null || imagePath.isEmpty) {
        results.add(result);
        continue;
      }
      if (result.content.any((p) => p is ImagePart)) {
        results.add(result);
        continue;
      }
      final part = await _imagePartForPath(imagePath);
      if (part == null) {
        results.add(result);
        continue;
      }
      changed = true;
      results.add(
        FunctionExecutionResult(
          id: result.id,
          name: result.name,
          isError: result.isError,
          arguments: result.arguments,
          content: [...result.content, part],
          metadata: result.metadata,
          timestamp: result.timestamp,
        ),
      );
    }
    if (!changed) return message;
    return FunctionExecutionResultMessage(
      results: results,
      timestamp: message.timestamp,
    );
  }

  Future<ImagePart?> _imagePartForPath(String rawPath) async {
    late final String path;
    try {
      path = assertGuestPathUnderHome(rawPath);
    } catch (_) {
      return null;
    }
    if (guestMediaKindForPath(path) != GuestMediaKind.image) return null;
    final bytes = await _readGuestFile(path);
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final prepared = prepareImageForModel(bytes, hintExtension: path);
      return ImagePart(base64Encode(prepared.bytes), prepared.mimeType);
    } catch (_) {
      return null;
    }
  }
}

final _inboxImagePath = RegExp(
  r'(/root/projects/[^/\s]+/inbox/[^\s\]]+\.(?:png|jpe?g|gif|webp|bmp|ico))',
  caseSensitive: false,
);

Iterable<String> _imagePathsInText(String text) {
  return _inboxImagePath.allMatches(text).map((m) => m.group(1)!);
}
