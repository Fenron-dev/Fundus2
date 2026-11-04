import 'package:path/path.dart' as p;

/// Subtitle formats that live as files beside a video.
const subtitleExtensions = {'srt', 'ass', 'ssa', 'vtt'};

/// A subtitle file that belongs to one video file of a work.
final class LibrarySubtitle {
  const LibrarySubtitle({
    required this.fileId,
    required this.filename,
    required this.relativePath,
    required this.absolutePath,
    this.sourceId = 'local',
    this.language,
    this.forced = false,
    this.hearingImpaired = false,
    this.sizeBytes = 0,
    this.contentRevision = '',
  });

  final String fileId;
  final String filename;
  final String relativePath;

  /// Empty for a file that is not on this device, like a track's.
  final String absolutePath;
  final String sourceId;

  /// ISO 639-1 where the name gives it away, otherwise null.
  final String? language;

  /// Only the parts of the dialogue that are not in the audio language.
  final bool forced;

  /// Sounds and speakers spelled out (SDH, CC).
  final bool hearingImpaired;
  final int sizeBytes;
  final String contentRevision;

  bool get isRemote => sourceId != 'local';

  String get format {
    final extension = p.extension(filename).toLowerCase();
    return extension.isEmpty ? '' : extension.substring(1);
  }

  /// What the subtitle menu shows: the language in words, the flags after it,
  /// and the file name only where nothing else says what this is.
  String get label {
    final name = language == null ? null : _languageNames[language];
    final parts = [
      name ?? p.basenameWithoutExtension(filename),
      if (forced) 'erzwungen',
      if (hearingImpaired) 'für Hörgeschädigte',
    ];
    return '${parts.join(' · ')} (Datei)';
  }

  LibrarySubtitle withLocation({
    required String absolutePath,
    required String sourceId,
  }) => LibrarySubtitle(
    fileId: fileId,
    filename: filename,
    relativePath: relativePath,
    absolutePath: absolutePath,
    sourceId: sourceId,
    language: language,
    forced: forced,
    hearingImpaired: hearingImpaired,
    sizeBytes: sizeBytes,
    contentRevision: contentRevision,
  );
}

/// Which subtitle belongs to which video.
///
/// `Film.mkv` takes `Film.srt`, `Film.de.srt` and `Film.en.forced.srt`. In a
/// work with a single video every subtitle belongs to it, which is how
/// `Subs/English.srt` in a film folder ends up where it should. A subtitle
/// that names no video of a work with several is left out rather than shown
/// with the wrong episode.
Map<String, List<LibrarySubtitle>> matchSubtitles(
  List<({String fileId, String filename})> videos,
  List<
    ({
      String fileId,
      String filename,
      String relativePath,
      int sizeBytes,
      String contentRevision,
    })
  >
  subtitles,
) {
  final result = <String, List<LibrarySubtitle>>{
    for (final video in videos) video.fileId: <LibrarySubtitle>[],
  };
  if (videos.isEmpty) return result;
  final stems = [
    for (final video in videos)
      (fileId: video.fileId, stem: _stem(video.filename)),
  ]..sort((a, b) => b.stem.length.compareTo(a.stem.length));
  for (final subtitle in subtitles) {
    if (!subtitleExtensions.contains(
      p.extension(subtitle.filename).toLowerCase().replaceFirst('.', ''),
    )) {
      continue;
    }
    final stem = _stem(subtitle.filename);
    String? owner;
    var remainder = stem;
    // The longest video name that this subtitle starts with: `Folge 1` must
    // not take the subtitles of `Folge 10`.
    for (final video in stems) {
      if (stem == video.stem) {
        owner = video.fileId;
        remainder = '';
        break;
      }
      if (stem.startsWith(video.stem) &&
          stem.length > video.stem.length &&
          _separators.contains(stem[video.stem.length])) {
        owner = video.fileId;
        remainder = stem.substring(video.stem.length + 1);
        break;
      }
    }
    if (owner == null && videos.length == 1) owner = videos.single.fileId;
    if (owner == null) continue;
    final tags = _tags(remainder);
    result[owner]!.add(
      LibrarySubtitle(
        fileId: subtitle.fileId,
        filename: subtitle.filename,
        relativePath: subtitle.relativePath,
        absolutePath: '',
        language: tags.language,
        forced: tags.forced,
        hearingImpaired: tags.hearingImpaired,
        sizeBytes: subtitle.sizeBytes,
        contentRevision: subtitle.contentRevision,
      ),
    );
  }
  for (final list in result.values) {
    list.sort((a, b) {
      final language = (a.language ?? '~').compareTo(b.language ?? '~');
      if (language != 0) return language;
      if (a.forced != b.forced) return a.forced ? 1 : -1;
      return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
    });
  }
  return result;
}

const _separators = {'.', '_', '-', ' ', '['};

String _stem(String filename) =>
    p.basenameWithoutExtension(filename).toLowerCase().trim();

({String? language, bool forced, bool hearingImpaired}) _tags(String text) {
  String? language;
  var forced = false;
  var hearingImpaired = false;
  for (final token in text.split(RegExp(r'[.\s_\-\[\]()]+'))) {
    if (token.isEmpty) continue;
    switch (token) {
      case 'forced' || 'erzwungen' || 'foreign':
        forced = true;
      case 'sdh' || 'cc' || 'hi':
        hearingImpaired = true;
      default:
        language ??= _languageCodes[token];
    }
  }
  return (language: language, forced: forced, hearingImpaired: hearingImpaired);
}

const _languageCodes = {
  'de': 'de',
  'ger': 'de',
  'deu': 'de',
  'german': 'de',
  'deutsch': 'de',
  'en': 'en',
  'eng': 'en',
  'english': 'en',
  'englisch': 'en',
  'fr': 'fr',
  'fre': 'fr',
  'fra': 'fr',
  'french': 'fr',
  'francais': 'fr',
  'es': 'es',
  'spa': 'es',
  'spanish': 'es',
  'espanol': 'es',
  'it': 'it',
  'ita': 'it',
  'italian': 'it',
  'italiano': 'it',
  'ja': 'ja',
  'jpn': 'ja',
  'japanese': 'ja',
  'jp': 'ja',
  'nl': 'nl',
  'dut': 'nl',
  'nld': 'nl',
  'dutch': 'nl',
  'pl': 'pl',
  'pol': 'pl',
  'polish': 'pl',
  'pt': 'pt',
  'por': 'pt',
  'portuguese': 'pt',
  'ru': 'ru',
  'rus': 'ru',
  'russian': 'ru',
  'sv': 'sv',
  'swe': 'sv',
  'swedish': 'sv',
  'da': 'da',
  'dan': 'da',
  'danish': 'da',
  'no': 'no',
  'nor': 'no',
  'norwegian': 'no',
  'fi': 'fi',
  'fin': 'fi',
  'finnish': 'fi',
  'tr': 'tr',
  'tur': 'tr',
  'turkish': 'tr',
  'zh': 'zh',
  'chi': 'zh',
  'zho': 'zh',
  'chinese': 'zh',
  'ko': 'ko',
  'kor': 'ko',
  'korean': 'ko',
  'ar': 'ar',
  'ara': 'ar',
  'arabic': 'ar',
  'cs': 'cs',
  'cze': 'cs',
  'ces': 'cs',
  'czech': 'cs',
  'hu': 'hu',
  'hun': 'hu',
  'hungarian': 'hu',
  'el': 'el',
  'gre': 'el',
  'ell': 'el',
  'greek': 'el',
};

const _languageNames = {
  'de': 'Deutsch',
  'en': 'Englisch',
  'fr': 'Französisch',
  'es': 'Spanisch',
  'it': 'Italienisch',
  'ja': 'Japanisch',
  'nl': 'Niederländisch',
  'pl': 'Polnisch',
  'pt': 'Portugiesisch',
  'ru': 'Russisch',
  'sv': 'Schwedisch',
  'da': 'Dänisch',
  'no': 'Norwegisch',
  'fi': 'Finnisch',
  'tr': 'Türkisch',
  'zh': 'Chinesisch',
  'ko': 'Koreanisch',
  'ar': 'Arabisch',
  'cs': 'Tschechisch',
  'hu': 'Ungarisch',
  'el': 'Griechisch',
};
