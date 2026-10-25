import '../model/media_position.dart';
import 'reflow_document.dart';

/// One piece of *original* reader text to speak. The end position is committed
/// only after the audio sink has actually played the complete piece, never
/// when synthesis or buffering finishes.
final class SpeechTextSegment {
  const SpeechTextSegment({
    required this.text,
    required this.start,
    required this.end,
    required this.paragraphIndex,
    required this.startPosition,
    required this.endPosition,
  });

  final String text;
  final int start;
  final int end;
  final int paragraphIndex;
  final MediaPosition startPosition;
  final MediaPosition endPosition;
}

/// Converts a reader chapter into bounded, position-aware speech pieces.
/// Speech transformations may change [SpeechTextSegment.text] later, but the
/// original offsets must remain attached to the audio that is played.
final class SpeechTextPlan {
  SpeechTextPlan({
    required this.document,
    required this.fileId,
    required this.chapterId,
    required this.at,
    this.maxCharacters = 400,
  }) {
    if (maxCharacters < 80 || maxCharacters > 1000) {
      throw ArgumentError.value(maxCharacters, 'maxCharacters');
    }
    if (at != null &&
        (at!.kind != MediaPositionKind.epubCfi ||
            at!.fileId != null && at!.fileId != fileId ||
            at!.chapterId != null && at!.chapterId != chapterId)) {
      throw const FormatException(
        'Vorlesestand gehört nicht zu diesem Kapitel.',
      );
    }
  }

  final ReflowDocument document;
  final String fileId;
  final String chapterId;
  final MediaPosition? at;
  final int maxCharacters;

  /// A changed paragraph ID means the reader had to fall back to an older
  /// character offset. The caller can warn rather than pretending this is an
  /// exact continuation in revised text.
  bool get reanchored {
    final id = at?.elementId;
    return id != null && !document.paragraphs.any((part) => part.id == id);
  }

  Iterable<SpeechTextSegment> get segments sync* {
    if (document.paragraphs.isEmpty) return;
    final resolved = document.resolve(at);
    for (
      var paragraphIndex = resolved.paragraphIndex;
      paragraphIndex < document.paragraphs.length;
      paragraphIndex++
    ) {
      final paragraph = document.paragraphs[paragraphIndex];
      final cursor = paragraphIndex == resolved.paragraphIndex
          ? (paragraph.text.length * resolved.innerOffset).round()
          : 0;
      if (cursor >= paragraph.text.length) continue;
      final sentences = _sentenceSpans(paragraph.text);
      for (final sentence in sentences) {
        if (sentence.end <= cursor) continue;
        for (final span in _boundedSpans(
          paragraph.text,
          sentence.start,
          sentence.end,
          maxCharacters,
        )) {
          MediaPosition position(int offset) => document.positionFor(
            paragraphIndex: paragraphIndex,
            innerOffset: paragraph.text.isEmpty
                ? 0
                : offset / paragraph.text.length,
            fileId: fileId,
            chapterId: chapterId,
          );
          yield SpeechTextSegment(
            text: paragraph.text.substring(span.start, span.end),
            start: span.start,
            end: span.end,
            paragraphIndex: paragraphIndex,
            startPosition: position(span.start),
            endPosition: position(span.end),
          );
        }
      }
    }
  }

  static const _abbreviations = {
    'dr',
    'prof',
    'mr',
    'mrs',
    'ms',
    'bzw',
    'ca',
    'vgl',
    'usw',
    'etc',
    'z',
    'b',
    'd',
    'h',
    'u',
    'a',
    's',
    'nr',
    'kap',
    'bd',
    'evtl',
    'ggf',
  };

  static Iterable<({int start, int end})> _sentenceSpans(String text) sync* {
    final boundary = RegExp(r'(?<=[.!?…])\s+');
    var start = 0;
    for (final match in boundary.allMatches(text)) {
      final candidate = text.substring(start, match.start).trimRight();
      final word = RegExp(r'(\w+)\W*$').firstMatch(candidate)?.group(1);
      if (candidate.endsWith('.') &&
          word != null &&
          (_abbreviations.contains(word.toLowerCase()) ||
              int.tryParse(word) != null)) {
        continue;
      }
      if (candidate.isNotEmpty) yield (start: start, end: match.start);
      start = match.end;
    }
    if (text.substring(start).trim().isNotEmpty) {
      yield (start: start, end: text.length);
    }
  }

  static Iterable<({int start, int end})> _boundedSpans(
    String text,
    int from,
    int to,
    int limit,
  ) sync* {
    var start = from;
    while (start < to) {
      while (start < to && _space.hasMatch(text[start])) {
        start++;
      }
      if (start >= to) break;
      var end = (start + limit).clamp(start, to);
      if (end < to) {
        final space = text.lastIndexOf(_space, end);
        if (space > start + limit ~/ 2) end = space;
      }
      // Dart offsets count UTF-16 code units. Never hand a synthesizer half
      // of a supplementary character when a long unbroken word is split.
      if (end < to &&
          end > start + 1 &&
          _highSurrogate(text.codeUnitAt(end - 1)) &&
          _lowSurrogate(text.codeUnitAt(end))) {
        end--;
      }
      while (end > start && _space.hasMatch(text[end - 1])) {
        end--;
      }
      if (end == start) end = (start + limit).clamp(start, to);
      yield (start: start, end: end);
      start = end;
    }
  }

  static final _space = RegExp(r'\s');

  static bool _highSurrogate(int value) => value >= 0xD800 && value <= 0xDBFF;
  static bool _lowSurrogate(int value) => value >= 0xDC00 && value <= 0xDFFF;
}
