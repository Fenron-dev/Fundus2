import 'dart:async';
import 'dart:typed_data';

import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;

import '../data/work_view.dart';
import 'podcast_feed.dart';

/// What changed on a work, for the one line that reports it.
final class MetadataApplyResult {
  const MetadataApplyResult({
    required this.workId,
    required this.title,
    required this.provider,
    this.coverFetched = false,
    this.coverFailed = false,
    this.backdropFetched = false,
    this.episodesDescribed = 0,
    this.feedRead = false,
  });

  final String workId;
  final String title;
  final String provider;
  final bool coverFetched;
  final bool coverFailed;

  /// Whether a wide picture came down with it.
  final bool backdropFetched;

  /// How many episodes got their own text out of the show's feed.
  final int episodesDescribed;

  /// Whether there was a feed to read at all. Without it, „keine Folge
  /// zugeordnet" would be a complaint about something nobody attempted.
  final bool feedRead;
}

/// Writes a chosen match onto a work.
///
/// Two rules decide what happens to what is already there:
///
/// - **A hand-made entry wins.** The metadata layer keeps, per field, who
///   last wrote it, and a value someone typed outranks a value a service
///   answered. Matching a work again therefore never overwrites a title
///   somebody corrected by hand — it fills in what is still empty.
/// - **A cover already in the folder wins.** A `cover.jpg` next to the files
///   is a decision someone made; a downloaded picture goes into the vault's
///   own cover cache and is used where there is nothing else.
Future<MetadataApplyResult> applyMetadata({
  required FundusLibrary library,
  required WorkView work,
  required MetadataCandidate candidate,
  http.Client? client,
  bool fetchCover = true,
}) async {
  final summary = work.summary;
  final authors = candidate.authors.isNotEmpty
      ? candidate.authors
      : [if (summary.author.trim().isNotEmpty) summary.author.trim()];
  await library.updateWorkMetadata(
    workId: work.id,
    title: candidate.title,
    authors: authors.isEmpty ? const ['Unbekannt'] : authors,
    series: candidate.series ?? summary.series,
    seriesSequence: candidate.seriesSequence ?? summary.seriesSequence,
    language: candidate.language,
    description: candidate.description,
    publisher: candidate.publisher,
    publishedYear: candidate.releaseYear,
    contentSensitivity: candidate.contentSensitivity,
    genres: candidate.genres.isEmpty ? null : candidate.genres,
    contentStyle: candidate.contentStyle,
    // Woher der Treffer kam — bei einem Podcast steckt darin die Adresse des
    // Feeds, und der Feed ist das Einzige, was etwas über die einzelnen
    // Folgen weiß.
    externalIds: candidate.externalIds.isEmpty ? null : candidate.externalIds,
    // Written as what it is: an answer from a service. The metadata layer
    // ranks a value someone typed above one a service gave, which is what
    // makes a correction survive the next match.
    source: WorkMetadataSource.online,
  );

  var fetched = false;
  var failed = false;
  final poster = candidate.posterUrl;
  // A `cover.jpg` in the folder is somebody's decision and is left alone. A
  // picture Fundus fetched earlier is not — it was the best answer at the
  // time, and this match is a newer one. Testing only for "has a cover at
  // all" meant a work that once got a picture could never get a better one,
  // and one whose first attempt failed stayed blank for good.
  if (fetchCover && poster != null && !summary.hasFolderCover) {
    final bytes = await fetchCoverBytes(poster, client: client);
    if (bytes == null) {
      failed = true;
    } else {
      await library.cacheGeneratedCover(
        workId: work.id,
        bytes: bytes,
        extension: poster.toLowerCase().endsWith('.png') ? 'png' : 'jpg',
      );
      fetched = true;
    }
  }
  // The wide picture is the one the stage and the head of a detail page
  // need, and no folder ever holds one — so unlike the cover it is fetched
  // whenever the match offers it and the work has none.
  var wide = false;
  final backdrop = candidate.backdropUrl;
  if (fetchCover && backdrop != null && summary.backdropPath == null) {
    final bytes = await fetchCoverBytes(backdrop, client: client);
    if (bytes != null) {
      await library.cacheBackdrop(
        workId: work.id,
        bytes: bytes,
        extension: backdrop.toLowerCase().endsWith('.png') ? 'png' : 'jpg',
      );
      wide = true;
    }
  }

  // Ein Podcast bringt die Adresse seines Feeds mit, und nur dort steht,
  // worum es in einer Folge geht. Ein Feed, der nicht antwortet, kostet die
  // Texte — nie den Abgleich.
  var described = 0;
  final feedUrl = candidate.externalIds['feed'];
  if (feedUrl != null) {
    described = await describeEpisodes(
      library: library,
      workId: work.id,
      feedUrl: feedUrl,
      client: client,
    );
  }

  return MetadataApplyResult(
    workId: work.id,
    title: candidate.title,
    provider: candidate.provider,
    coverFetched: fetched,
    coverFailed: failed,
    backdropFetched: wide,
    episodesDescribed: described,
    feedRead: feedUrl != null,
  );
}

/// A cover is worth one attempt and no drama.
///
/// A work with the right title and no picture is a better outcome than a
/// failed match, so a picture that will not come down is reported and
/// otherwise ignored.
Future<Uint8List?> fetchCoverBytes(String url, {http.Client? client}) async {
  final own = client == null;
  final fetcher = client ?? http.Client();
  try {
    final response = await fetcher
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    if (response.bodyBytes.isEmpty) return null;
    return response.bodyBytes;
  } on Object {
    return null;
  } finally {
    if (own) fetcher.close();
  }
}

/// Writes what a show's feed says about each of its episodes.
///
/// Matched by the file name the feed's enclosure points at, and otherwise by
/// the title with the punctuation taken out — a downloader renames both, but
/// rarely the same way. What does not match is simply left alone: an episode
/// without a text is a worse outcome than a wrong one only for a moment.
///
/// Returns how many episodes ended up with something to read.
Future<int> describeEpisodes({
  required FundusLibrary library,
  required String workId,
  required String feedUrl,
  http.Client? client,
}) async {
  if (library.isReadOnly) return 0;
  final feed = PodcastFeed(client: client);
  try {
    final episodes = await feed.read(feedUrl);
    if (episodes.isEmpty) return 0;
    final matched = matchEpisodes(episodes, [
      for (final track in library.playbackTracks(workId))
        EpisodeFile(fileId: track.fileId, name: track.title),
    ]);
    for (final entry in matched.entries) {
      final episode = episodes[entry.key];
      library.setFileDetail(
        workId: workId,
        fileId: entry.value,
        title: episode.title,
        description: episode.description,
        publishedAt: episode.publishedAt,
      );
    }
    return matched.length;
  } on Object {
    // A feed that will not answer costs the texts, never the match.
    return 0;
  } finally {
    if (client == null) feed.close();
  }
}
