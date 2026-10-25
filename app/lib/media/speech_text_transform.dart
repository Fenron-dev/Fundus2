import 'package:fundus_core/fundus_core.dart';

/// Applies device-local, per-work pronunciation hints to speech only.
/// Reader text and its position anchors remain untouched.
final class SpeechTextTransform {
  const SpeechTextTransform._();

  static SpeechTextSegment apply(
    SpeechTextSegment segment,
    Map<String, String> pronunciations,
  ) {
    if (pronunciations.isEmpty) return segment;
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
}
