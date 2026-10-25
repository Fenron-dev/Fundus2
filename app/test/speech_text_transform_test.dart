import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/speech_text_transform.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  test('Aussprache ändert nur den gesprochenen Text, nicht dessen Anker', () {
    const position = MediaPosition(
      kind: MediaPositionKind.epubCfi,
      numericValue: 0.25,
      fileId: 'chapter-1',
      chapterId: 'chapter-1',
      elementId: 'p-7',
      label: 'Absatz 7',
    );
    const segment = SpeechTextSegment(
      text: 'The name Ryo appears; Ryo is not Ryoko.',
      start: 40,
      end: 80,
      paragraphIndex: 3,
      startPosition: position,
      endPosition: position,
    );

    final spoken = SpeechTextTransform.apply(segment, const {
      'Ryo': 'Rio',
      'appears': 'uh-pears',
    });

    expect(spoken.text, 'The name Rio uh-pears; Rio is not Ryoko.');
    expect(segment.text, 'The name Ryo appears; Ryo is not Ryoko.');
    expect(spoken.start, segment.start);
    expect(spoken.end, segment.end);
    expect(spoken.paragraphIndex, segment.paragraphIndex);
    expect(spoken.startPosition, position);
    expect(spoken.endPosition, position);
  });

  test('längere Begriffe werden zuerst ersetzt und Unicode bleibt korrekt', () {
    const position = MediaPosition(
      kind: MediaPositionKind.epubCfi,
      numericValue: 0,
    );
    const segment = SpeechTextSegment(
      text: 'Éowyn and Éowyn the Brave.',
      start: 0,
      end: 26,
      paragraphIndex: 0,
      startPosition: position,
      endPosition: position,
    );

    final spoken = SpeechTextTransform.apply(segment, const {
      'Éowyn': 'A-o-win',
      'Éowyn the Brave': 'A-o-win the Brave',
    });

    expect(spoken.text, 'A-o-win and A-o-win the Brave.');
  });
}
