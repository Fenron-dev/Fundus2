import 'playback_engine.dart';

/// Which language a person watches in.
///
/// A track id is a position inside one file. Episode two of the same series
/// can carry its tracks in the other order, so remembering „track 2" means
/// remembering nothing — the choice has to be remembered as a language and
/// found again by language in the next file.
///
/// Codes are the mess they are: the same language turns up as `de`, `deu`,
/// `ger`, `de-DE`, sometimes as `German` in the title. Matching is therefore
/// on a normalised form and by family rather than by string equality.
final class TrackPreference {
  const TrackPreference({this.audioLanguage, this.subtitleLanguage});

  factory TrackPreference.fromJson(Map<String, Object?> value) =>
      TrackPreference(
        audioLanguage: value['audio_language'] as String?,
        subtitleLanguage: value['subtitle_language'] as String?,
      );

  /// The language of the audio track last chosen by hand.
  final String? audioLanguage;

  /// Same for subtitles. The literal `off` is a choice like any other — the
  /// person who switched subtitles off meant it.
  final String? subtitleLanguage;

  static const off = 'off';

  Map<String, Object?> toJson() => {
    'audio_language': audioLanguage,
    'subtitle_language': subtitleLanguage,
  };

  TrackPreference withAudio(String? language) => TrackPreference(
    audioLanguage: language,
    subtitleLanguage: subtitleLanguage,
  );

  TrackPreference withSubtitle(String? language) =>
      TrackPreference(audioLanguage: audioLanguage, subtitleLanguage: language);

  /// The audio track to pick in a file, or null to leave it alone.
  MediaTrackOption? audioFor(List<MediaTrackOption> tracks) =>
      _match(tracks, audioLanguage);

  /// The subtitle track to pick, `off` included.
  MediaTrackOption? subtitleFor(List<MediaTrackOption> tracks) {
    final wanted = subtitleLanguage;
    if (wanted == null) return null;
    if (wanted == off) {
      for (final track in tracks) {
        if (track.id == 'no') return track;
      }
      return null;
    }
    return _match(tracks, wanted);
  }

  static MediaTrackOption? _match(
    List<MediaTrackOption> tracks,
    String? wanted,
  ) {
    if (wanted == null || wanted.isEmpty) return null;
    final target = normalise(wanted);
    if (target.isEmpty) return null;
    for (final track in tracks) {
      if (track.id == 'auto' || track.id == 'no') continue;
      final language = normalise(track.language ?? '');
      if (language.isNotEmpty && language == target) return track;
    }
    // Nothing in that language: leave the file's own choice standing rather
    // than pick something arbitrary that is merely not it.
    return null;
  }

  /// Reduces a language tag to something two of them can be compared by.
  ///
  /// `de`, `deu`, `ger`, `de-DE` and `German` are one language; ISO 639 gives
  /// German three codes on its own, and files use all of them.
  static String normalise(String value) {
    final lower = value.trim().toLowerCase();
    if (lower.isEmpty) return '';
    final base = lower.split(RegExp('[-_]')).first;
    return _families[base] ?? base;
  }

  static const _families = <String, String>{
    'de': 'de',
    'deu': 'de',
    'ger': 'de',
    'german': 'de',
    'deutsch': 'de',
    'en': 'en',
    'eng': 'en',
    'english': 'en',
    'ja': 'ja',
    'jpn': 'ja',
    'japanese': 'ja',
    'japanisch': 'ja',
    'fr': 'fr',
    'fra': 'fr',
    'fre': 'fr',
    'french': 'fr',
    'es': 'es',
    'spa': 'es',
    'spanish': 'es',
    'it': 'it',
    'ita': 'it',
    'italian': 'it',
    'nl': 'nl',
    'nld': 'nl',
    'dut': 'nl',
    'dutch': 'nl',
    'pt': 'pt',
    'por': 'pt',
    'portuguese': 'pt',
    'ru': 'ru',
    'rus': 'ru',
    'russian': 'ru',
    'zh': 'zh',
    'zho': 'zh',
    'chi': 'zh',
    'chinese': 'zh',
    'ko': 'ko',
    'kor': 'ko',
    'korean': 'ko',
  };
}
