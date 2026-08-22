abstract class ModelContentPart {
  Map<String, dynamic> toJson();

  static ModelContentPart fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    switch (type) {
      case 'text':
        return ModelTextPart.fromJson(json);
      case 'image':
        return ModelImagePart.fromJson(json);
      case 'video':
        return ModelVideoPart.fromJson(json);
      default:
        throw Exception('Unknown content part type: $type');
    }
  }
}

class ModelTextPart extends ModelContentPart {
  final String text;
  ModelTextPart(this.text);

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};

  factory ModelTextPart.fromJson(Map<String, dynamic> json) {
    return ModelTextPart(json['text'] as String);
  }
}

class ModelImagePart extends ModelContentPart {
  final String base64Data;
  final String? mimeType;
  final Map<String, dynamic>? metadata;
  ModelImagePart(this.base64Data, {this.mimeType, this.metadata});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'base64Data': base64Data,
    if (mimeType != null) 'mimeType': mimeType,
    'metadata': metadata,
  };

  factory ModelImagePart.fromJson(Map<String, dynamic> json) {
    return ModelImagePart(
      json['base64Data'],
      mimeType: json['mimeType'] as String?,
      metadata: json['metadata'],
    );
  }
}

class ModelVideoPart extends ModelContentPart {
  final String base64Data;
  final String? mimeType;
  final Map<String, dynamic>? metadata;
  ModelVideoPart(this.base64Data, {this.mimeType, this.metadata});

  @override
  Map<String, dynamic> toJson() => {
    'type': 'video',
    'base64Data': base64Data,
    if (mimeType != null) 'mimeType': mimeType,
    'metadata': metadata,
  };

  factory ModelVideoPart.fromJson(Map<String, dynamic> json) {
    return ModelVideoPart(
      json['base64Data'],
      mimeType: json['mimeType'] as String?,
      metadata: json['metadata'],
    );
  }
}

class ModelAudioPart extends ModelContentPart {
  final String? base64Data;
  final String? mimeType;
  final String? transcript;
  final Map<String, dynamic>? metadata;
  ModelAudioPart({
    this.base64Data,
    this.mimeType,
    this.metadata,
    this.transcript,
  });

  @override
  Map<String, dynamic> toJson() => {
    'type': 'audio',
    if (base64Data != null) 'base64Data': base64Data,
    if (mimeType != null) 'mimeType': mimeType,
    if (transcript != null) 'transcript': transcript,
    'metadata': metadata,
  };

  factory ModelAudioPart.fromJson(Map<String, dynamic> json) {
    return ModelAudioPart(
      base64Data: json['base64Data'] as String?,
      mimeType: json['mimeType'] as String?,
      transcript: json['transcript'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }
}
