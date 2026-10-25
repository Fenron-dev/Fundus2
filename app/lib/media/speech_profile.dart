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
    this.maxCharacters = 400,
    this.sentencePauseMs = 120,
    this.paragraphPauseMs = 600,
    this.chapterPauseMs = 1500,
    this.textRules = const [],
  });

  final String id;
  final String name;
  final String language;
  final String modelDirectory;
  final String? voicesDirectory;
  final String? voice;
  final List<String> dictionaryIds;
  final int maxCharacters;
  final int sentencePauseMs;
  final int paragraphPauseMs;
  final int chapterPauseMs;
  final List<String> textRules;

  SpeechProfile copyWith({List<String>? dictionaryIds}) => SpeechProfile(
    id: id,
    name: name,
    language: language,
    modelDirectory: modelDirectory,
    voicesDirectory: voicesDirectory,
    voice: voice,
    dictionaryIds: dictionaryIds ?? this.dictionaryIds,
    maxCharacters: maxCharacters,
    sentencePauseMs: sentencePauseMs,
    paragraphPauseMs: paragraphPauseMs,
    chapterPauseMs: chapterPauseMs,
    textRules: textRules,
  );

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
    maxCharacters: (value['max_characters'] as num?)?.toInt() ?? 400,
    sentencePauseMs: (value['sentence_pause_ms'] as num?)?.toInt() ?? 120,
    paragraphPauseMs: (value['paragraph_pause_ms'] as num?)?.toInt() ?? 600,
    chapterPauseMs: (value['chapter_pause_ms'] as num?)?.toInt() ?? 1500,
    textRules: (value['text_rules'] as List? ?? [])
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
    'max_characters': maxCharacters,
    'sentence_pause_ms': sentencePauseMs,
    'paragraph_pause_ms': paragraphPauseMs,
    'chapter_pause_ms': chapterPauseMs,
    'text_rules': textRules,
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
