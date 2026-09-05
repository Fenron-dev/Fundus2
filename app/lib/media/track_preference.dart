import 'playback_engine.dart';

/// When subtitles come on by themselves.
enum SubtitleRule {
  /// Whatever the file was made with. Nothing is switched.
  asFile('Wie in der Datei'),

  /// Never, unless somebody turns them on for this film.
  never('Aus'),

  /// Only where the audio is in a language this person did not list as one
  /// they follow — an anime that exists in English only, say.
  whenForeign('Nur wenn ich den Ton nicht verstehe'),

  /// Always, in the chosen language where the file has it.
  always('Immer');

  const SubtitleRule(this.label);

  final String label;

  static SubtitleRule byName(String? value) {
    for (final rule in SubtitleRule.values) {
      if (rule.name == value) return rule;
    }
    return SubtitleRule.asFile;
  }
}

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
///
/// Two things live here at once, and they are not the same: what somebody
/// last picked by hand, and the standing rule they set once in the settings.
/// The hand-made choice wins where the file has it; the rule decides
/// everything else.
final class TrackPreference {
  const TrackPreference({
    this.audioLanguage,
    this.subtitleLanguage,
    this.audioWishes = const [],
    this.understood = const [],
    this.subtitleRule = SubtitleRule.asFile,
    this.subtitleWish,
  });

  factory TrackPreference.fromJson(Map<String, Object?> value) =>
      TrackPreference(
        audioLanguage: value['audio_language'] as String?,
        subtitleLanguage: value['subtitle_language'] as String?,
        audioWishes: _strings(value['audio_wishes']),
        understood: _strings(value['understood']),
        subtitleRule: SubtitleRule.byName(value['subtitle_rule'] as String?),
        subtitleWish: value['subtitle_wish'] as String?,
      );

  /// The language of the audio track last chosen by hand.
  final String? audioLanguage;

  /// Same for subtitles. The literal `off` is a choice like any other — the
  /// person who switched subtitles off meant it.
  final String? subtitleLanguage;

  /// The standing wish, best first: German, then English, say.
  ///
  /// A hand-made choice still wins where the file has that language — it is
  /// the more recent and more specific statement. The wish decides everything
  /// else, which is what makes it a default rather than a second memory.
  final List<String> audioWishes;

  /// The languages this person follows without help. Only the foreign rule
  /// reads it.
  final List<String> understood;

  final SubtitleRule subtitleRule;

  /// Which language the rule turns on.
  final String? subtitleWish;

  static const off = 'off';

  Map<String, Object?> toJson() => {
    'audio_language': audioLanguage,
    'subtitle_language': subtitleLanguage,
    'audio_wishes': audioWishes,
    'understood': understood,
    'subtitle_rule': subtitleRule.name,
    'subtitle_wish': subtitleWish,
  };

  TrackPreference withAudio(String? language) =>
      _copy(audioLanguage: language, keepAudio: false);

  TrackPreference withSubtitle(String? language) =>
      _copy(subtitleLanguage: language, keepSubtitle: false);

  /// The standing rules, as set in the settings.
  ///
  /// Setting them forgets what was last chosen by hand: a default nobody can
  /// see take effect is not a default.
  TrackPreference withRules({
    required List<String> audioWishes,
    required List<String> understood,
    required SubtitleRule subtitleRule,
    String? subtitleWish,
  }) => TrackPreference(
    audioWishes: audioWishes,
    understood: understood,
    subtitleRule: subtitleRule,
    subtitleWish: subtitleWish,
  );

  TrackPreference _copy({
    String? audioLanguage,
    String? subtitleLanguage,
    bool keepAudio = true,
    bool keepSubtitle = true,
  }) => TrackPreference(
    audioLanguage: keepAudio ? this.audioLanguage : audioLanguage,
    subtitleLanguage: keepSubtitle ? this.subtitleLanguage : subtitleLanguage,
    audioWishes: audioWishes,
    understood: understood,
    subtitleRule: subtitleRule,
    subtitleWish: subtitleWish,
  );

  /// The audio track to pick in a file, or null to leave it alone.
  MediaTrackOption? audioFor(List<MediaTrackOption> tracks) {
    if (_match(tracks, audioLanguage) case final chosen?) return chosen;
    for (final wish in audioWishes) {
      if (_match(tracks, wish) case final track?) return track;
    }
    return null;
  }

  /// The subtitle track to pick, `off` included.
  ///
  /// [audioLanguage] is the language actually playing, which the foreign rule
  /// turns on: what matters is not what was wished for but what came out.
  MediaTrackOption? subtitleFor(
    List<MediaTrackOption> tracks, {
    String? spokenLanguage,
  }) {
    final chosen = subtitleLanguage;
    if (chosen != null) {
      if (chosen == off) return _silent(tracks);
      if (_match(tracks, chosen) case final track?) return track;
    }
    return switch (subtitleRule) {
      SubtitleRule.asFile => null,
      SubtitleRule.never => _silent(tracks),
      SubtitleRule.always => _match(tracks, subtitleWish),
      SubtitleRule.whenForeign =>
        _follows(spokenLanguage)
            ? _silent(tracks)
            : _match(tracks, subtitleWish),
    };
  }

  /// Whether the person reads this language without subtitles.
  ///
  /// A language they asked for in the audio counts as one they follow: asking
  /// to hear German and then reading German subtitles under it is nobody's
  /// wish.
  bool _follows(String? language) {
    if (language == null) return false;
    final target = normalise(language);
    if (target.isEmpty) return false;
    for (final entry in [...understood, ...audioWishes]) {
      if (normalise(entry) == target) return true;
    }
    return false;
  }

  static MediaTrackOption? _silent(List<MediaTrackOption> tracks) {
    for (final track in tracks) {
      if (track.id == 'no') return track;
    }
    return null;
  }

  static List<String> _strings(Object? value) => value is List
      ? value.whereType<String>().toList(growable: false)
      : const [];

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
