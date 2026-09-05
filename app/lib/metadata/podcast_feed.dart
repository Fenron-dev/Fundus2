import 'dart:async';

import 'package:http/http.dart' as http;
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
  PodcastFeed({http.Client? client}) : _client = client ?? http.Client();

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

/// Which local file an entry belongs to.
///
/// The file name from the enclosure first, because it survives everything
/// else; then the title, compared without the punctuation and numbering that
/// downloaders add and remove at will.
String? matchEpisode(FeedEpisode episode, Map<String, String> filesByName) {
  final fileName = episode.fileName;
  if (fileName != null) {
    final direct = filesByName[normaliseEpisodeName(fileName)];
    if (direct != null) return direct;
  }
  return filesByName[normaliseEpisodeName(episode.title)];
}

/// A name reduced to what two spellings of it have in common.
String normaliseEpisodeName(String value) {
  final withoutExtension = value.replaceFirst(
    RegExp(r'\.(mp3|m4a|aac|ogg|opus|flac|wav)$', caseSensitive: false),
    '',
  );
  return withoutExtension
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9äöüß]+'), '')
      .trim();
}
