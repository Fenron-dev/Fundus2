import 'package:fundus_core/fundus_core.dart';
import 'speech_text_rules.dart';

final class SpeechTextPiece {
  const SpeechTextPiece({required this.text, this.pauseAfter = Duration.zero});
  final String text;
  final Duration pauseAfter;
}

/// Applies device-local, per-work pronunciation hints to speech only.
/// Reader text and its position anchors remain untouched.
final class SpeechTextTransform {
  const SpeechTextTransform._();

  static SpeechTextSegment apply(
    SpeechTextSegment segment,
    Map<String, String> pronunciations, {
    Set<String> rules = const {},
    String language = 'en',
  }) {
    var text = segment.text;
    final entries = pronunciations.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));
    for (final entry in entries) {
      final source = entry.key.trim();
      final spoken = entry.value.trim();
      if (source.isEmpty || spoken.isEmpty) continue;
      final pattern = RegExp(
        '(?<![\\p{L}\\p{N}])${RegExp.escape(source)}(?![\\p{L}\\p{N}])',
        caseSensitive: false,
        unicode: true,
      );
      text = text.replaceAll(pattern, spoken);
    }
    text = SpeechTextRules.apply(text, rules, language);
    if (text == segment.text) return segment;
    return SpeechTextSegment(
      text: text,
      start: segment.start,
      end: segment.end,
      paragraphIndex: segment.paragraphIndex,
      startPosition: segment.startPosition,
      endPosition: segment.endPosition,
    );
  }

  static List<SpeechTextPiece> splitPauses(String text) {
    final result = <SpeechTextPiece>[];
    final pause = RegExp(
      r'\[\s*pause(?:\s+([0-9]+(?:[.,][0-9]+)?)\s*s?)?\s*\]',
      caseSensitive: false,
    );
    var offset = 0;
    for (final match in pause.allMatches(text)) {
      final part = text.substring(offset, match.start).trim();
      if (part.isNotEmpty) {
        result.add(
          SpeechTextPiece(
            text: part,
            pauseAfter: Duration(
              milliseconds:
                  ((double.tryParse(
                                (match.group(1) ?? '1').replaceAll(',', '.'),
                              ) ??
                              1) *
                          1000)
                      .round()
                      .clamp(0, 30000),
            ),
          ),
        );
      }
      offset = match.end;
    }
    final tail = text.substring(offset).trim();
    if (tail.isNotEmpty) result.add(SpeechTextPiece(text: tail));
    return result.isEmpty ? [SpeechTextPiece(text: text)] : result;
  }
}
