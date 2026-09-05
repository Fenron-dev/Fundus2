import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/playback_engine.dart';
import 'package:fundus/media/track_preference.dart';

/// Watching in the language you watch in.
///
/// Track ids are positions inside one file, so a remembered id is worth
/// nothing in the next episode — and that was the complaint: every new file
/// came back in Japanese.
void main() {
  const japanese = MediaTrackOption(id: '1', label: '日本語', language: 'jpn');
  const german = MediaTrackOption(id: '2', label: 'Deutsch', language: 'ger');
  const english = MediaTrackOption(id: '3', label: 'English', language: 'en');
  const off = MediaTrackOption(id: 'no', label: 'Aus');

  test('dieselbe Sprache in drei Schreibweisen ist eine Sprache', () {
    expect(TrackPreference.normalise('de'), TrackPreference.normalise('deu'));
    expect(TrackPreference.normalise('ger'), TrackPreference.normalise('de'));
    expect(TrackPreference.normalise('de-DE'), TrackPreference.normalise('de'));
    expect(
      TrackPreference.normalise('German'),
      TrackPreference.normalise('de'),
    );
    expect(
      TrackPreference.normalise('jpn'),
      isNot(TrackPreference.normalise('de')),
    );
  });

  test('die gemerkte Sprache wird in der nächsten Folge wiedergefunden', () {
    const preference = TrackPreference(audioLanguage: 'deu');

    expect(preference.audioFor([japanese, german])?.id, '2');

    // Folge zwei hat Deutsch als erste Spur — genau der Fall, an dem eine
    // gemerkte Spurnummer scheitert und eine gemerkte Sprache trägt.
    const nextEpisode = [
      MediaTrackOption(id: '1', label: 'Deutsch', language: 'de'),
      MediaTrackOption(id: '2', label: '日本語', language: 'jpn'),
    ];
    expect(preference.audioFor(nextEpisode)?.id, '1');
  });

  test('fehlt die Sprache, bleibt die Wahl der Datei stehen', () {
    const preference = TrackPreference(audioLanguage: 'deu');

    expect(preference.audioFor([japanese, english]), isNull);
  });

  test('Untertitel aus heißt aus, nicht irgendeine Sprache', () {
    const preference = TrackPreference(subtitleLanguage: TrackPreference.off);

    expect(preference.subtitleFor([off, german])?.id, 'no');
  });

  test('ohne gemerkte Sprache wird nichts umgestellt', () {
    const preference = TrackPreference();

    expect(preference.audioFor([japanese, german]), isNull);
    expect(preference.subtitleFor([off, german]), isNull);
  });

  test('die Wahl übersteht das Ablegen und Einlesen', () {
    const preference = TrackPreference(
      audioLanguage: 'ger',
      subtitleLanguage: TrackPreference.off,
    );

    final read = TrackPreference.fromJson(preference.toJson());

    expect(read.audioLanguage, 'ger');
    expect(read.subtitleLanguage, TrackPreference.off);
  });

  group('Die Standardsprache gilt, wenn niemand etwas sagt', () {
    const rules = TrackPreference(
      audioWishes: ['de', 'en'],
      subtitleRule: SubtitleRule.whenForeign,
      subtitleWish: 'de',
    );

    test('Deutsch wird genommen, wo es Deutsch gibt', () {
      expect(rules.audioFor([japanese, german, english])?.id, '2');
      // Und ohne Untertitel: der gewünschte Ton zählt als verstanden.
      expect(rules.subtitleFor([off, german], spokenLanguage: 'ger')?.id, 'no');
    });

    test('sonst die zweite Wahl', () {
      expect(rules.audioFor([japanese, english])?.id, '3');
    });

    test('bleibt nur eine fremde Sprache, kommen Untertitel an', () {
      const onlyJapanese = TrackPreference(
        audioWishes: ['de'],
        subtitleRule: SubtitleRule.whenForeign,
        subtitleWish: 'de',
      );
      final subtitles = [off, german];

      // Der Ton bleibt, wie die Datei ihn hat — erzwungen wird nichts.
      expect(onlyJapanese.audioFor([japanese]), isNull);
      expect(
        onlyJapanese.subtitleFor(subtitles, spokenLanguage: 'jpn')?.id,
        '2',
      );
    });

    test('was von Hand gewählt wurde, schlägt die Vorgabe', () {
      const chosen = TrackPreference(audioLanguage: 'jpn', audioWishes: ['de']);

      expect(chosen.audioFor([japanese, german])?.id, '1');
      // Und wo es die Handwahl nicht gibt, trägt wieder die Vorgabe.
      expect(chosen.audioFor([german, english])?.id, '2');
    });

    test('eine neue Vorgabe vergisst die alte Handwahl', () {
      const chosen = TrackPreference(audioLanguage: 'jpn');
      final fresh = chosen.withRules(
        audioWishes: const ['de'],
        understood: const [],
        subtitleRule: SubtitleRule.never,
      );

      expect(fresh.audioLanguage, isNull);
      expect(fresh.audioFor([japanese, german])?.id, '2');
    });

    test('ohne Regel wird nichts umgeschaltet', () {
      const nothing = TrackPreference();

      expect(nothing.audioFor([japanese, german]), isNull);
      expect(nothing.subtitleFor([off, german], spokenLanguage: 'jpn'), isNull);
    });

    test('eine Regel übersteht das Speichern', () {
      final restored = TrackPreference.fromJson(rules.toJson());

      expect(restored.audioWishes, ['de', 'en']);
      expect(restored.subtitleRule, SubtitleRule.whenForeign);
      expect(restored.subtitleWish, 'de');
    });
  });
}
