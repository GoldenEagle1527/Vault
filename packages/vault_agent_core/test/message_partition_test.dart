import 'package:test/test.dart';
import 'package:vault_agent_core/src/core/message.dart';

void main() {
  group('message compatibility facade', () {
    test('preserves concrete message factories and JSON shapes', () {
      final messages = <LLMMessage>[
        SystemMessage('system'),
        UserMessage(
          [
            TextPart('hello'),
            ImagePart('image', 'image/png', detail: 'high'),
            VideoPart('video', 'video/mp4'),
            AudioPart('audio', 'audio/wav'),
            DocumentPart('document', 'application/pdf'),
          ],
          timestamp: 10,
          metadata: {'source': 'test'},
        ),
        ModelMessage(
          thought: 'thinking',
          thoughtSignature: 'signature',
          contentBlocks: [
            {'type': 'thinking', 'thinking': 'thinking'},
          ],
          functionCalls: [
            FunctionCall(id: 'call-1', name: 'lookup', arguments: '{}'),
          ],
          textOutput: 'answer',
          imageOutputs: [
            ModelImagePart(
              'image',
              mimeType: 'image/png',
              metadata: {'width': 1},
            ),
          ],
          videoOutputs: [
            ModelVideoPart(
              'video',
              mimeType: 'video/mp4',
              metadata: {'duration': 1},
            ),
          ],
          audioOutputs: [
            ModelAudioPart(
              base64Data: 'audio',
              mimeType: 'audio/wav',
              transcript: 'spoken',
              metadata: {'duration': 1},
            ),
          ],
          usage: ModelUsage(
            promptTokens: 1,
            completionTokens: 2,
            totalTokens: 3,
            cachedToken: 4,
            thoughtToken: 5,
            model: 'model',
            originalUsage: {'input_tokens': 1},
            timestamp: 20,
          ),
          metadata: {'provider': 'test'},
          stopReason: 'stop',
          model: 'model',
          responseId: 'response-1',
          timestamp: 30,
        ),
        FunctionExecutionResultMessage(
          results: [
            FunctionExecutionResult(
              id: 'call-1',
              name: 'lookup',
              isError: false,
              arguments: '{}',
              content: [TextPart('result')],
              metadata: {'provider': 'test'},
              timestamp: 40,
            ),
          ],
          timestamp: 50,
        ),
      ];

      for (final message in messages) {
        final json = message.toJson();
        expect(LLMMessage.fromJson(json).toJson(), json);
      }
    });

    test('preserves content-part factories and model audio behavior', () {
      final userParts = <UserContentPart>[
        TextPart('text'),
        ImagePart('image', 'image/png', detail: 'low'),
        VideoPart('video', 'video/mp4'),
        AudioPart('audio', 'audio/wav'),
        DocumentPart('document', 'application/pdf'),
      ];
      for (final part in userParts) {
        expect(UserContentPart.fromJson(part.toJson()).toJson(), part.toJson());
      }

      final modelParts = <ModelContentPart>[
        ModelTextPart('text'),
        ModelImagePart('image', mimeType: 'image/png'),
        ModelVideoPart('video', mimeType: 'video/mp4'),
      ];
      for (final part in modelParts) {
        expect(
          ModelContentPart.fromJson(part.toJson()).toJson(),
          part.toJson(),
        );
      }

      final audio = ModelAudioPart(
        base64Data: 'audio',
        mimeType: 'audio/wav',
        transcript: 'text',
      );
      expect(ModelAudioPart.fromJson(audio.toJson()).toJson(), audio.toJson());
      expect(
        () => ModelContentPart.fromJson(audio.toJson()),
        throwsA(isA<Exception>()),
      );
    });

    test('preserves streaming constructors', () {
      final event = StreamingEvent(
        eventType: StreamingEventType.modelChunkMessage,
        data: ModelMessage(model: 'model', timestamp: 60),
      );

      expect(event.eventType, StreamingEventType.modelChunkMessage);
      expect(event.data, isA<ModelMessage>());
    });
  });
}
