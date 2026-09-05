import 'dart:async';
import 'dart:typed_data';

import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;

import '../data/work_view.dart';

/// What changed on a work, for the one line that reports it.
final class MetadataApplyResult {
  const MetadataApplyResult({
    required this.workId,
    required this.title,
    required this.provider,
    this.coverFetched = false,
    this.coverFailed = false,
  });

  final String workId;
  final String title;
  final String provider;
  final bool coverFetched;
  final bool coverFailed;
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
    // Written as what it is: an answer from a service. The metadata layer
    // ranks a value someone typed above one a service gave, which is what
    // makes a correction survive the next match.
    source: WorkMetadataSource.online,
  );

  var fetched = false;
  var failed = false;
  final poster = candidate.posterUrl;
  if (fetchCover && poster != null && summary.coverPath == null) {
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
  return MetadataApplyResult(
    workId: work.id,
    title: candidate.title,
    provider: candidate.provider,
    coverFetched: fetched,
    coverFailed: failed,
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
