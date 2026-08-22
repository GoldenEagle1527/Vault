/// Base class for user content parts.
abstract class UserContentPart {
  Map<String, dynamic> toJson();

  static UserContentPart fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    switch (type) {
      case 'text':
        return TextPart.fromJson(json);
      case 'image':
        return ImagePart.fromJson(json);
      case 'video':
        return VideoPart.fromJson(json);
      case 'audio':
        return AudioPart.fromJson(json);
      case 'document':
        return DocumentPart.fromJson(json);
      default:
        throw Exception('Unknown content part type: $type');
    }
  }
}

class TextPart extends UserContentPart {
  final String text;
  TextPart(this.text);

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};

  factory TextPart.fromJson(Map<String, dynamic> json) {
    return TextPart(json['text'] as String);
  }
}

class ImagePart extends UserContentPart {
  final String base64Data;
  final String mimeType;
  final String? detail;
  ImagePart(this.base64Data, this.mimeType, {this.detail});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'base64Data': base64Data,
    'mimeType': mimeType,
    if (detail != null) 'detail': detail,
  };

  factory ImagePart.fromJson(Map<String, dynamic> json) {
    return ImagePart(
      json['base64Data'],
      json['mimeType'] as String,
      detail: json['detail'],
    );
  }
}

class VideoPart extends UserContentPart {
  final String base64Data;
  final String mimeType;
  VideoPart(this.base64Data, this.mimeType);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'video',
    'base64Data': base64Data,
    'mimeType': mimeType,
  };

  factory VideoPart.fromJson(Map<String, dynamic> json) {
    return VideoPart(json['base64Data'], json['mimeType'] as String);
  }
}

class AudioPart extends UserContentPart {
  final String base64Data;
  final String mimeType;
  AudioPart(this.base64Data, this.mimeType);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'audio',
    'base64Data': base64Data,
    'mimeType': mimeType,
  };

  factory AudioPart.fromJson(Map<String, dynamic> json) {
    return AudioPart(json['base64Data'], json['mimeType'] as String);
  }
}

class DocumentPart extends UserContentPart {
  final String base64Data;
  final String mimeType;
  DocumentPart(this.base64Data, this.mimeType);

  @override
  Map<String, dynamic> toJson() => {
    'type': 'document',
    'base64Data': base64Data,
    'mimeType': mimeType,
  };

  factory DocumentPart.fromJson(Map<String, dynamic> json) {
    return DocumentPart(json['base64Data'], json['mimeType'] as String);
  }
}
