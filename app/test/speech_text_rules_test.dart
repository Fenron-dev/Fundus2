import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/speech_text_rules.dart';
import 'package:fundus/media/speech_text_transform.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  test(
    'Deutschregeln normalisieren alte ß-Schreibung, Zahlen und Abkürzungen',
    () {
      final value = SpeechTextRules.apply(
        'daß Dr. Müller von 1980–1989 schrieb.',
        {'old_spelling', 'abbrev_de', 'ranges_de'},
        'de',
      );
      expect(value, 'dass Doktor Müller von 1980 bis 1989 schrieb.');
    },
  );

  test('ß-Regel schützt langes ß, globale ss-Regel dagegen nicht', () {
    expect(
      SpeechTextRules.apply('daß Straße groß', {'old_spelling'}, 'de'),
      'dass Straße groß',
    );
    expect(
      SpeechTextRules.apply('daß Straße groß', {'sz_to_ss'}, 'de'),
      'dass Strasse gross',
    );
  });

  test('Gedankenstriche werden zu echten Pausenmarken', () {
    final pieces = SpeechTextTransform.splitPauses(
      SpeechTextRules.apply('Wait — then continue.', {'dash_pause'}, 'en'),
    );
    expect(pieces.map((piece) => piece.text), ['Wait', 'then continue.']);
    expect(pieces.first.pauseAfter, const Duration(milliseconds: 400));
  });

  test(
    'Phonon-Pausenmarker akzeptieren deutsches Dezimalkomma und Sekunden',
    () {
      final pieces = SpeechTextTransform.splitPauses(
        'First [pause 2,5s] second [pause] third',
      );
      expect(pieces.map((piece) => piece.text), ['First', 'second', 'third']);
      expect(pieces[0].pauseAfter, const Duration(milliseconds: 2500));
      expect(pieces[1].pauseAfter, const Duration(seconds: 1));
    },
  );

  test(
    'Anführungszeichen lassen sich entfernen ohne den Originaltext zu ändern',
    () {
      const position = MediaPosition(
        kind: MediaPositionKind.epubCfi,
        numericValue: 0,
      );
      const segment = SpeechTextSegment(
        text: '„Hello,“ she said.',
        start: 0,
        end: 18,
        paragraphIndex: 0,
        startPosition: position,
        endPosition: position,
      );
      final transformed = SpeechTextTransform.apply(
        segment,
        const {},
        rules: {'quotes'},
      );
      expect(transformed.text, 'Hello, she said.');
      expect(segment.text, '„Hello,“ she said.');
      expect(transformed.startPosition, position);
    },
  );
}
