import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('englische Werkmetadaten wählen Englisch statt deutschem Standard', () {
    final choice = SpeechLanguageResolver.resolve(
      workMetadata: 'EN-us',
      mediaTypeDefault: 'de',
      globalDefault: 'de',
    )!;
    expect(choice.language, SpeechLanguage.english);
    expect(choice.source, SpeechLanguageSource.workMetadata);
    expect(SpeechLanguageResolver.code(choice.language), 'en');
  });

  test('bewusste Werkswahl schlägt eingebettete Metadaten', () {
    final choice = SpeechLanguageResolver.resolve(
      workOverride: 'English',
      workMetadata: 'de-DE',
      publicationMetadata: 'ger',
    )!;
    expect(choice.language, SpeechLanguage.english);
    expect(choice.source, SpeechLanguageSource.workOverride);
  });

  test('EPUB-Sprache schlägt einen Medientyp-Standard', () {
    final choice = SpeechLanguageResolver.resolve(
      publicationMetadata: 'eng',
      mediaTypeDefault: 'de',
    )!;
    expect(choice.language, SpeechLanguage.english);
    expect(choice.source, SpeechLanguageSource.publicationMetadata);
  });

  test('englischer Novel-Standard greift erst ohne brauchbare Metadaten', () {
    final choice = SpeechLanguageResolver.resolve(
      workMetadata: 'unbekannt',
      mediaTypeDefault: 'en',
      globalDefault: 'de',
    )!;
    expect(choice.language, SpeechLanguage.english);
    expect(choice.source, SpeechLanguageSource.mediaTypeDefault);
  });

  test('ohne verlässliche Sprache ist eine explizite Auswahl nötig', () {
    expect(SpeechLanguageResolver.resolve(), isNull);
    expect(SpeechLanguageResolver.parse('xx'), isNull);
    expect(SpeechLanguageResolver.parse(''), isNull);
  });

  test('unbekannte bewusste Sprachwahl fällt nicht still auf Deutsch', () {
    expect(
      SpeechLanguageResolver.resolve(
        workOverride: 'ja',
        workMetadata: 'de',
        globalDefault: 'de',
      ),
      isNull,
    );
  });

  test('unterstützte Sprachcodes bleiben eindeutig', () {
    expect(SpeechLanguageResolver.parse('de_AT'), SpeechLanguage.german);
    expect(SpeechLanguageResolver.parse('fr-CA'), SpeechLanguage.french);
    expect(SpeechLanguageResolver.parse('spa'), SpeechLanguage.spanish);
    expect(SpeechLanguageResolver.parse('pt-BR'), SpeechLanguage.portuguese);
  });
}
