/// The normalization language used by Phonon. A voice and model must also
/// support this language; a matching display name alone is not sufficient.
enum SpeechLanguage { english, german, french, spanish, portuguese }

enum SpeechLanguageSource {
  workOverride,
  workMetadata,
  publicationMetadata,
  mediaTypeDefault,
  globalDefault,
}

final class SpeechLanguageSelection {
  const SpeechLanguageSelection({required this.language, required this.source});

  final SpeechLanguage language;
  final SpeechLanguageSource source;
}

/// Resolves a language without guessing from a title or silently falling back
/// to German. A null result means the reader must request a choice before TTS.
final class SpeechLanguageResolver {
  const SpeechLanguageResolver._();

  static SpeechLanguageSelection? resolve({
    String? workOverride,
    String? workMetadata,
    String? publicationMetadata,
    String? mediaTypeDefault,
    String? globalDefault,
  }) {
    // A deliberate but unsupported choice must not silently speak in another
    // language just because a lower-priority metadata value happens to exist.
    if (workOverride != null && workOverride.trim().isNotEmpty) {
      final language = parse(workOverride);
      return language == null
          ? null
          : SpeechLanguageSelection(
              language: language,
              source: SpeechLanguageSource.workOverride,
            );
    }
    final candidates = [
      (workMetadata, SpeechLanguageSource.workMetadata),
      (publicationMetadata, SpeechLanguageSource.publicationMetadata),
      (mediaTypeDefault, SpeechLanguageSource.mediaTypeDefault),
      (globalDefault, SpeechLanguageSource.globalDefault),
    ];
    for (final (value, source) in candidates) {
      final language = parse(value);
      if (language != null) {
        return SpeechLanguageSelection(language: language, source: source);
      }
    }
    return null;
  }

  /// Known ISO 639-1/2 names and simple BCP-47 tags. Unknown values are not
  /// treated as English or German, because that would select the wrong model.
  static SpeechLanguage? parse(String? value) {
    final normalized = value?.trim().toLowerCase().replaceAll('_', '-');
    if (normalized == null || normalized.isEmpty) return null;
    final primary = normalized.split('-').first;
    return switch (primary) {
      'en' || 'eng' || 'english' => SpeechLanguage.english,
      'de' || 'deu' || 'ger' || 'german' || 'deutsch' => SpeechLanguage.german,
      'fr' || 'fra' || 'fre' || 'french' || 'français' => SpeechLanguage.french,
      'es' || 'spa' || 'spanish' || 'español' => SpeechLanguage.spanish,
      'pt' || 'por' || 'portuguese' || 'português' => SpeechLanguage.portuguese,
      _ => null,
    };
  }

  static String code(SpeechLanguage language) => switch (language) {
    SpeechLanguage.english => 'en',
    SpeechLanguage.german => 'de',
    SpeechLanguage.french => 'fr',
    SpeechLanguage.spanish => 'es',
    SpeechLanguage.portuguese => 'pt',
  };
}
