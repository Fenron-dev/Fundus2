/// Phonon-style, language-specific cleanup applied to generated speech text.
/// The document and its reading anchors are never modified.
final class SpeechTextRuleDefinition {
  const SpeechTextRuleDefinition({
    required this.id,
    required this.title,
    required this.description,
    this.languages = const {'de', 'en'},
  });

  final String id;
  final String title;
  final String description;
  final Set<String> languages;
}

abstract final class SpeechTextRules {
  static const definitions = <SpeechTextRuleDefinition>[
    SpeechTextRuleDefinition(
      id: 'old_spelling',
      title: 'Alte deutsche Rechtschreibung',
      description:
          'Wandelt ß nach kurzem Vokal um; Straße, groß, Fuß, Gruß und verwandte lange Vokale bleiben.',
      languages: {'de'},
    ),
    SpeechTextRuleDefinition(
      id: 'sz_to_ss',
      title: 'ß immer als ss sprechen',
      description: 'Grober Ersatz: auch Straße wird zu Strasse.',
      languages: {'de'},
    ),
    SpeechTextRuleDefinition(
      id: 'abbrev_de',
      title: 'Deutsche Abkürzungen ausschreiben',
      description: 'Zum Beispiel „z. B.“ und „d. h.“.',
      languages: {'de'},
    ),
    SpeechTextRuleDefinition(
      id: 'ranges_de',
      title: 'Zahlenbereiche als „bis“ sprechen',
      description: 'Zum Beispiel 1980–1989.',
      languages: {'de'},
    ),
    SpeechTextRuleDefinition(
      id: 'ampersand',
      title: '& als „und“ sprechen',
      description: 'Löst das kaufmännische Und in Namen und Text auf.',
    ),
    SpeechTextRuleDefinition(
      id: 'caps',
      title: 'GROSSBUCHSTABEN normalisieren',
      description: 'Liest längere Versalien wie normale Wörter.',
    ),
    SpeechTextRuleDefinition(
      id: 'quotes',
      title: 'Anführungszeichen entfernen',
      description: 'Hilft, wenn die Stimme bei typografischen Zitaten stockt.',
    ),
    SpeechTextRuleDefinition(
      id: 'footnote_marks',
      title: 'Fußnotenzeichen entfernen',
      description: 'Entfernt Sternchen und Ziffernverweise hinter Wörtern.',
    ),
    SpeechTextRuleDefinition(
      id: 'dash_pause',
      title: 'Gedankenstriche als kurze Pause',
      description:
          'Setzt eine kurze Pause an Gedankenstrichen und Trennstrichen.',
    ),
    SpeechTextRuleDefinition(
      id: 'ellipsis_pause',
      title: 'Auslassungspunkte als Pause',
      description: 'Setzt eine längere Pause bei … und drei Punkten.',
    ),
  ];

  static List<SpeechTextRuleDefinition> forLanguage(String language) =>
      definitions.where((rule) => rule.languages.contains(language)).toList();

  static String apply(String input, Set<String> enabled, String language) {
    var text = input;
    if (language == 'de' && enabled.contains('old_spelling')) {
      text = _oldGermanSpelling(text);
    } else if (language == 'de' && enabled.contains('sz_to_ss')) {
      text = text.replaceAll('ß', 'ss').replaceAll('ẞ', 'SS');
    }
    if (language == 'de' && enabled.contains('abbrev_de')) {
      const replacements = <String, String>{
        r'\bz\.?\s?B\.': 'zum Beispiel',
        r'\bd\.?\s?h\.': 'das heißt',
        r'\bu\.?\s?a\.': 'unter anderem',
        r'\bo\.?\s?ä\.': 'oder ähnlich',
        r'\bs\.?\s?o\.': 'siehe oben',
        r'\bs\.?\s?u\.': 'siehe unten',
        r'\bi\.?\s?d\.?\s?R\.': 'in der Regel',
        r'\bu\.?\s?U\.': 'unter Umständen',
        r'\bz\.?\s?T\.': 'zum Teil',
        r'\bbzw\.': 'beziehungsweise',
        r'\busw\.': 'und so weiter',
        r'\bca\.': 'circa',
        r'\bvgl\.': 'vergleiche',
        r'\betc\.': 'et cetera',
        r'\bggf\.': 'gegebenenfalls',
        r'\bevtl\.': 'eventuell',
        r'\binkl\.': 'inklusive',
        r'\bDr\.': 'Doktor',
        r'\bProf\.': 'Professor',
        r'\bSt\.': 'Sankt',
        r'\bHr\.': 'Herr',
        r'\bFr\.': 'Frau',
        r'\bKap\.': 'Kapitel',
        r'\bNr\.': 'Nummer',
        r'\bS\.(?=\s?\d)': 'Seite',
      };
      for (final entry in replacements.entries) {
        text = text.replaceAll(
          RegExp(entry.key, caseSensitive: false),
          entry.value,
        );
      }
    }
    if (language == 'de' && enabled.contains('ranges_de')) {
      text = text.replaceAllMapped(
        RegExp(r'(?<=\d)\s?[–—-]\s?(?=\d)'),
        (_) => ' bis ',
      );
    }
    if (enabled.contains('ampersand')) {
      text = text.replaceAll(RegExp(r'\s*&\s*'), ' und ');
    }
    if (enabled.contains('caps')) {
      final caps = RegExp(
        r'\b[A-ZÄÖÜ]{2,}(?:[\s,;:–-]+[A-ZÄÖÜ]{1,})+\b|\b[A-ZÄÖÜ]{5,}\b',
      );
      text = text.replaceAllMapped(caps, (match) {
        return match
            .group(0)!
            .replaceAllMapped(
              RegExp(r'\w+'),
              (word) => word
                  .group(0)!
                  .toLowerCase()
                  .replaceFirstMapped(
                    RegExp(r'^.'),
                    (first) => first.group(0)!.toUpperCase(),
                  ),
            );
      });
    }
    if (enabled.contains('quotes')) {
      text = text.replaceAll(RegExp('[„“”»«‚‘›‹"“”]'), '');
    }
    if (enabled.contains('footnote_marks')) {
      text = text.replaceAll(
        RegExp(r'(?<=\w)[*†‡¹²³⁴⁵⁶⁷⁸⁹⁰]+|\s?\[\d{1,3}\]'),
        '',
      );
    }
    if (enabled.contains('dash_pause')) {
      text = text.replaceAll(RegExp(r'\s+[–—-]\s+|[–—]'), ' [pause 0.4] ');
    }
    if (enabled.contains('ellipsis_pause')) {
      text = text.replaceAll(RegExp(r'\s*(…|\.\.\.)\s*'), ' [pause 0.6] ');
    }
    return text.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
  }

  static String _oldGermanSpelling(String text) {
    final protected = RegExp(
      r'^(aß|äße?|aßen|saß|saßen|säße|fraß|fraßen|maß|maße|vergaß|vergaßen|vergäße|ruß|fuß)$',
      caseSensitive: false,
    );
    final longVowel = RegExp(r'(ei|ai|au|äu|eu|ie)$', caseSensitive: false);
    const longStems = [
      'fuß',
      'füß',
      'gruß',
      'grüß',
      'spaß',
      'späß',
      'stoß',
      'stöß',
      'floß',
      'flöß',
      'bloß',
      'blöß',
      'groß',
      'größ',
      'süß',
      'ruß',
      'kloß',
      'klöß',
      'schoß',
      'schöß',
      'gefäß',
      'gemäß',
      'mäßig',
      'maßen',
      'maßnahm',
      'maßstab',
      'maßgeb',
      'büß',
      'buße',
      'muße',
      'straß',
      'sträß',
      'soß',
      'gesäß',
      'schweiß',
      'fraß',
      'fräß',
      'spieß',
    ];
    return text.replaceAllMapped(RegExp(r'[A-Za-zÄÖÜäöü]*ß[A-Za-zÄÖÜäöüß]*'), (
      match,
    ) {
      final word = match.group(0)!;
      final lower = word.toLowerCase();
      if (protected.hasMatch(lower) || longStems.any(lower.contains)) {
        return word;
      }
      final result = StringBuffer();
      for (var i = 0; i < word.length; i++) {
        if (word[i] != 'ß') {
          result.write(word[i]);
          continue;
        }
        final before = lower.substring(i >= 2 ? i - 2 : 0, i);
        result.write(longVowel.hasMatch(before) ? 'ß' : 'ss');
      }
      return result.toString();
    });
  }
}
