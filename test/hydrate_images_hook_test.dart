import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vault/agent/chat_attachment.dart';
import 'package:vault/agent/hydrate_images_hook.dart';
import 'package:vault/sandbox/guest_media_kind.dart';
import 'package:vault_agent_core/vault_agent_core.dart';

Uint8List _png() {
  final image = img.Image(width: 12, height: 10);
  img.fill(image, color: img.ColorRgb8(9, 8, 7));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  test('UserMessage JSON keeps attachment paths and no base64', () {
    final msg = UserMessage(
      [TextPart('看这张图')],
      metadata: {
        'attachments': [
          const ChatAttachmentMeta(
            guestPath: '/root/projects/p1/inbox/shot.png',
            displayName: 'shot.png',
            kind: GuestMediaKind.image,
          ).toJson(),
        ],
      },
    );
    final encoded = jsonEncode(msg.toJson());
    expect(encoded, isNot(contains('base64Data')));
    expect(encoded, contains('/root/projects/p1/inbox/shot.png'));
    expect(msg.contents.whereType<ImagePart>(), isEmpty);
  });

  test('hydrate adds ImagePart on the request copy only', () async {
    final png = _png();
    final files = <String, Uint8List>{'/root/projects/p1/inbox/shot.png': png};
    final original = UserMessage(
      [TextPart('看这张图')],
      metadata: {
        'attachments': [
          const ChatAttachmentMeta(
            guestPath: '/root/projects/p1/inbox/shot.png',
            displayName: 'shot.png',
            kind: GuestMediaKind.image,
          ).toJson(),
        ],
      },
    );
    final hook = HydrateConversationImagesHook((path) async => files[path]);
    final hydrated = await hook.hydrateMessages([original]);

    expect(hydrated.single, isNot(same(original)));
    expect(original.contents.whereType<ImagePart>(), isEmpty);
    expect(jsonEncode(original.toJson()), isNot(contains('base64Data')));

    final copy = hydrated.single as UserMessage;
    final images = copy.contents.whereType<ImagePart>().toList();
    expect(images, hasLength(1));
    expect(images.single.mimeType, 'image/png');
    expect(base64Decode(images.single.base64Data), png);
  });

  test('hydrate also picks inbox image paths from user text', () async {
    final png = _png();
    final hook = HydrateConversationImagesHook((path) async {
      if (path == '/root/projects/demo/inbox/a.jpg') return png;
      return null;
    });
    final original = UserMessage.text('文件在 /root/projects/demo/inbox/a.jpg 里');
    final hydrated = await hook.hydrateMessages([original]);
    final copy = hydrated.single as UserMessage;
    expect(copy.contents.whereType<ImagePart>(), hasLength(1));
    expect(original.contents.whereType<ImagePart>(), isEmpty);
  });
}
