import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  final document = ReflowDocument.parse(
    'Dr. Morgen las den ersten Satz. Danach kam der zweite Satz.\n\n'
    'Ein neues Kapitel beginnt hier.',
    format: ReflowSourceFormat.plainText,
  );

  test('Vorlesen beginnt am Satz der Leseposition und behält Textanker', () {
    final at = document.positionFor(
      paragraphIndex: 0,
      innerOffset: 0.68,
      fileId: 'band-1',
      chapterId: 'kapitel-1',
    );
    final plan = SpeechTextPlan(
      document: document,
      fileId: 'band-1',
      chapterId: 'kapitel-1',
      at: at,
    );
    final segments = plan.segments.toList();
    expect(plan.reanchored, false);
    expect(segments.first.text, 'Danach kam der zweite Satz.');
    expect(segments.first.startPosition.fileId, 'band-1');
    expect(segments.first.endPosition.chapterId, 'kapitel-1');
    expect(document.resolve(segments.first.endPosition).paragraphIndex, 0);
    expect(segments.last.text, 'Ein neues Kapitel beginnt hier.');
  });

  test('Abkürzungen trennen keinen gesprochenen Satz', () {
    final first = SpeechTextPlan(
      document: document,
      fileId: 'band-1',
      chapterId: 'kapitel-1',
      at: null,
      groupSentences: false,
    ).segments.first;
    expect(first.text, 'Dr. Morgen las den ersten Satz.');
  });

  test('größere Profile bündeln Sätze, Sprungsegmente bleiben satzgenau', () {
    final grouped = SpeechTextPlan(
      document: document,
      fileId: 'band-1',
      chapterId: 'kapitel-1',
      at: null,
      maxCharacters: 400,
    ).segments.first;
    final sentence = SpeechTextPlan(
      document: document,
      fileId: 'band-1',
      chapterId: 'kapitel-1',
      at: null,
      maxCharacters: 400,
      groupSentences: false,
    ).segments.first;
    expect(
      grouped.text,
      'Dr. Morgen las den ersten Satz. Danach kam der zweite Satz.',
    );
    expect(sentence.text, 'Dr. Morgen las den ersten Satz.');
    expect(
      document.paragraphs[0].text.substring(grouped.start, grouped.end),
      grouped.text,
    );
  });

  test('lange Abschnitte bleiben begrenzt und zeigen auf Originaltext', () {
    final long = ReflowDocument.parse(
      List.filled(120, 'Wort').join(' '),
      format: ReflowSourceFormat.plainText,
    );
    final parts = SpeechTextPlan(
      document: long,
      fileId: 'text',
      chapterId: 'document',
      at: null,
      maxCharacters: 80,
    ).segments.toList();
    expect(parts.length, greaterThan(1));
    for (final part in parts) {
      expect(part.text.length, lessThanOrEqualTo(80));
      expect(
        long.paragraphs[0].text.substring(part.start, part.end),
        part.text,
      );
      expect(part.endPosition.numericValue, greaterThan(part.start));
    }
    expect(parts.last.end, long.paragraphs[0].text.length);
  });

  test('ein langer Text trennt kein Emoji in zwei UTF-16-Hälften', () {
    final emoji = ReflowDocument.parse(
      List.filled(100, '😀').join(),
      format: ReflowSourceFormat.plainText,
    );
    final parts = SpeechTextPlan(
      document: emoji,
      fileId: 'text',
      chapterId: 'document',
      at: null,
      maxCharacters: 81,
    ).segments.toList();
    expect(parts.length, greaterThan(1));
    expect(parts.map((part) => part.text).join(), emoji.paragraphs[0].text);
    for (final part in parts) {
      expect(part.text.length, lessThanOrEqualTo(81));
      expect(part.text.runes.length * 2, part.text.length);
    }
  });

  test('falscher Band oder falsches Kapitel wird nicht vorgelesen', () {
    final at = document.positionFor(
      paragraphIndex: 0,
      innerOffset: 0,
      fileId: 'fremd',
      chapterId: 'kapitel-1',
    );
    expect(
      () => SpeechTextPlan(
        document: document,
        fileId: 'band-1',
        chapterId: 'kapitel-1',
        at: at,
      ),
      throwsFormatException,
    );
  });

  test('geänderter Textanker ist ausdrücklich erkennbar', () {
    final at = document.positionFor(
      paragraphIndex: 0,
      innerOffset: .2,
      fileId: 'band-1',
      chapterId: 'kapitel-1',
    );
    final changed = ReflowDocument.parse(
      'Der Absatz hat sich inhaltlich verändert.',
      format: ReflowSourceFormat.plainText,
    );
    final plan = SpeechTextPlan(
      document: changed,
      fileId: 'band-1',
      chapterId: 'kapitel-1',
      at: at,
    );
    expect(plan.reanchored, true);
    expect(
      plan.segments.first.text,
      'Der Absatz hat sich inhaltlich verändert.',
    );
  });
}
