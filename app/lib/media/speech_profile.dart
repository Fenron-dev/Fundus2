/// Device-local paths are references, never copies of model or voice files.
final class SpeechProfile {
  const SpeechProfile({
    required this.id,
    required this.name,
    required this.language,
    required this.modelDirectory,
    this.voicesDirectory,
    this.voice,
    this.dictionaryIds = const [],
  });

  final String id;
  final String name;
  final String language;
  final String modelDirectory;
  final String? voicesDirectory;
  final String? voice;
  final List<String> dictionaryIds;

  factory SpeechProfile.fromJson(Map value) => SpeechProfile(
    id: value['id'] as String,
    name: value['name'] as String,
    language: value['language'] as String,
    modelDirectory: value['model_directory'] as String,
    voicesDirectory: value['voices_directory'] as String?,
    voice: value['voice'] as String?,
    dictionaryIds: (value['dictionary_ids'] as List? ?? [])
        .whereType<String>()
        .toList(),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'language': language,
    'model_directory': modelDirectory,
    'voices_directory': voicesDirectory,
    'voice': voice,
    'dictionary_ids': dictionaryIds,
  };
}

final class SpeechDictionary {
  const SpeechDictionary({
    required this.id,
    required this.name,
    this.language,
    this.entries = const {},
  });
  final String id;
  final String name;
  final String? language;
  final Map<String, String> entries;

  factory SpeechDictionary.fromJson(Map value) => SpeechDictionary(
    id: value['id'] as String,
    name: value['name'] as String,
    language: value['language'] as String?,
    entries: Map<String, String>.from(value['entries'] as Map? ?? {}),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'language': language,
    'entries': entries,
  };
}
