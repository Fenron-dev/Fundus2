import 'dart:async';

import 'package:http/http.dart' as http;

import 'metadata_http_client.dart';
import 'package:xml/xml.dart';

/// One episode as the show's own feed describes it.
final class FeedEpisode {
  const FeedEpisode({
    required this.title,
    this.description,
    this.publishedAt,
    this.fileName,
  });

  final String title;
  final String? description;
  final DateTime? publishedAt;

  /// The file name the enclosure points at, where there is one. It is the
  /// surest way to match an entry to a file on disk — surer than the title,
  /// which gets renamed on the way down.
  final String? fileName;
}

/// Reads a podcast's RSS feed.
///
/// What a folder of MP3s cannot say: what an episode is about, when it came
/// out, and what it is really called. That lives in the feed, whose address
/// the directory match brings along.
final class PodcastFeed {
  PodcastFeed({http.Client? client})
    : _client = client ?? createMetadataHttpClient();

  final http.Client _client;

  Future<List<FeedEpisode>> read(String url) async {
    final response = await _client
        .get(Uri.parse(url), headers: const {'accept': 'application/rss+xml'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Der Feed hat mit ${response.statusCode} geantwortet.');
    }
    return parseFeed(response.body);
  }

  void close() => _client.close();
}

/// The episodes in a feed document.
///
/// Written as a function so a test can hand it a document rather than a
/// server, and so a malformed feed costs an empty list rather than a crash.
List<FeedEpisode> parseFeed(String body) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(body);
  } on XmlException {
    return const [];
  }
  final episodes = <FeedEpisode>[];
  for (final item in document.findAllElements('item')) {
    final title = _text(item, 'title');
    if (title == null) continue;
    episodes.add(
      FeedEpisode(
        title: title,
        description: _clean(
          _text(item, 'itunes:summary') ??
              _text(item, 'summary') ??
              _text(item, 'description'),
        ),
        publishedAt: _date(_text(item, 'pubDate')),
        fileName: _enclosureName(item),
      ),
    );
  }
  return episodes;
}

String? _text(XmlElement item, String name) {
  final element = item.findElements(name).firstOrNull;
  final value = element?.innerText.trim();
  return value == null || value.isEmpty ? null : value;
}

String? _enclosureName(XmlElement item) {
  final url = item.findElements('enclosure').firstOrNull?.getAttribute('url');
  if (url == null) return null;
  final path = Uri.tryParse(url)?.path;
  if (path == null || path.isEmpty) return null;
  final name = path.split('/').last;
  return name.isEmpty ? null : name;
}

/// Feeds carry HTML in their descriptions. What is wanted is the sentence.
String? _clean(String? value) {
  if (value == null) return null;
  final text = value
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return text.isEmpty ? null : text;
}

/// RFC 822 dates, as feeds write them: `Tue, 02 Sep 2025 05:00:00 +0000`.
DateTime? _date(String? value) {
  if (value == null) return null;
  final match = RegExp(
    r'(\d{1,2})\s+(\w{3})\s+(\d{4})(?:\s+(\d{2}):(\d{2})(?::(\d{2}))?)?',
  ).firstMatch(value);
  if (match == null) return DateTime.tryParse(value);
  const months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };
  final month = months[match.group(2)!.toLowerCase()];
  if (month == null) return null;
  return DateTime.utc(
    int.parse(match.group(3)!),
    month,
    int.parse(match.group(1)!),
    int.tryParse(match.group(4) ?? '') ?? 0,
    int.tryParse(match.group(5) ?? '') ?? 0,
    int.tryParse(match.group(6) ?? '') ?? 0,
  );
}

/// One local file, as the matcher sees it.
final class EpisodeFile {
  const EpisodeFile({required this.fileId, required this.name});

  final String fileId;

  /// The file's name, extension and all.
  final String name;
}

/// Which local file each feed entry belongs to.
///
/// Nothing about this is exact. The feed calls an episode „Auf ein Bier 042 —
/// Über Hefe", the file on disk is `AeB_042.mp3`, and neither knows about the
/// other. So it is tried in order of how much a match would mean, a file is
/// never given away twice, and what stays unmatched simply keeps no text:
///
/// 1. the file name the enclosure points at, which sometimes survives whole;
/// 2. the title, letter for letter, once punctuation is gone;
/// 3. one name contained in the other — a file named after the episode with
///    the show's name in front of it, or the other way round;
/// 4. the episode number, and only where it is unique on both sides. Two
///    files claiming number 42 are worse than no answer.
///
/// Returns, per episode, the file id it belongs to.
Map<int, String> matchEpisodes(
  List<FeedEpisode> episodes,
  List<EpisodeFile> files,
) {
  final matched = <int, String>{};
  final taken = <String>{};

  void assign(int episode, String fileId) {
    if (matched.containsKey(episode) || taken.contains(fileId)) return;
    matched[episode] = fileId;
    taken.add(fileId);
  }

  String? fileFor(bool Function(EpisodeFile file) test) {
    EpisodeFile? found;
    for (final file in files) {
      if (taken.contains(file.fileId) || !test(file)) continue;
      // Zwei Kandidaten sind keine Antwort.
      if (found != null) return null;
      found = file;
    }
    return found?.fileId;
  }

  for (var index = 0; index < episodes.length; index++) {
    final wanted = episodes[index].fileName;
    if (wanted == null) continue;
    final needle = normaliseEpisodeName(wanted);
    if (needle.isEmpty) continue;
    final fileId = fileFor((file) => normaliseEpisodeName(file.name) == needle);
    if (fileId != null) assign(index, fileId);
  }

  for (var index = 0; index < episodes.length; index++) {
    final needle = normaliseEpisodeName(episodes[index].title);
    if (needle.isEmpty) continue;
    final fileId = fileFor((file) => normaliseEpisodeName(file.name) == needle);
    if (fileId != null) assign(index, fileId);
  }

  for (var index = 0; index < episodes.length; index++) {
    final needle = normaliseEpisodeName(episodes[index].title);
    // Unter sechs Zeichen ist „enthalten" ein Zufall, keine Aussage.
    if (needle.length < 6) continue;
    final fileId = fileFor((file) {
      final name = normaliseEpisodeName(file.name);
      if (name.length < 6) return false;
      return name.contains(needle) || needle.contains(name);
    });
    if (fileId != null) assign(index, fileId);
  }

  for (var index = 0; index < episodes.length; index++) {
    final number = episodeNumberIn(episodes[index].title);
    if (number == null) continue;
    // Nur wenn die Nummer auch im Feed nur einmal vorkommt.
    final twice = episodes.where((other) {
      return episodeNumberIn(other.title) == number;
    }).length;
    if (twice != 1) continue;
    final fileId = fileFor((file) => episodeNumberIn(file.name) == number);
    if (fileId != null) assign(index, fileId);
  }

  return matched;
}

/// The episode number a name carries, if it carries one.
///
/// „SF 100", „AeB_042", „Folge 7" — the first run of digits that is not a
/// year and not part of a longer number. A four-digit number between 1900 and
/// 2100 is read as a year and skipped, because „Rückblick 1999" is not
/// episode one thousand nine hundred and ninety-nine.
int? episodeNumberIn(String value) {
  final withoutExtension = value.replaceFirst(
    RegExp(r'\.[a-z0-9]{2,4}$', caseSensitive: false),
    '',
  );
  for (final match in RegExp(r'\d+').allMatches(withoutExtension)) {
    final number = int.tryParse(match.group(0)!);
    if (number == null || number == 0) continue;
    if (match.group(0)!.length == 4 && number >= 1900 && number <= 2100) {
      continue;
    }
    return number;
  }
  return null;
}

/// A name reduced to what two spellings of it have in common.
String normaliseEpisodeName(String value) {
  final withoutExtension = value.replaceFirst(
    RegExp(r'\.(mp3|m4a|m4b|aac|ogg|opus|flac|wav)$', caseSensitive: false),
    '',
  );
  return withoutExtension
      .toLowerCase()
      .replaceAll('ä', 'a')
      .replaceAll('ö', 'o')
      .replaceAll('ü', 'u')
      .replaceAll('ß', 'ss')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '')
      .trim();
}
