import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;

import '../data/work_view.dart';
import 'podcast_feed.dart';

/// Which part of a match may be written.
///
/// Screenshot-driven: a match is rarely right in every field at once. The
/// English title may be the better one while the German blurb is not, and a
/// cover somebody is happy with should survive a match that only fixes the
/// year. So the choice is per field, and everything not chosen keeps what it
/// has.
enum MetadataField {
  title('Titel'),
  authors('Urheber'),
  series('Reihe & Band'),
  year('Jahr'),
  publisher('Verlag'),
  language('Sprache'),
  genres('Genres'),
  description('Beschreibung'),
  cover('Titelbild'),
  backdrop('Breitbild');

  const MetadataField(this.label);

  final String label;
}

/// A picked match together with what of it should be written.
///
/// An empty [fields] is „nur verknüpfen": the work remembers where it was
/// found — the id at the service, a podcast's feed — and not one visible
/// field changes. That is what makes a later, deliberate match possible
/// without touching anything today.
final class MetadataChoice {
  const MetadataChoice({required this.candidate, this.fields});

  final MetadataCandidate candidate;

  /// `null` means everything the match knows.
  final Set<MetadataField>? fields;

  bool get linkOnly => fields != null && fields!.isEmpty;
}

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
    this.peopleFound = 0,
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

  /// Wie viele Beteiligte der Abgleich mitgebracht hat.
  final int peopleFound;
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
  Set<MetadataField>? fields,
}) async {
  final summary = work.summary;
  // Was nicht gewählt wurde, bekommt seinen bisherigen Wert zurück — nicht
  // `null`. Ein leeres Feld ist für die Metadatenschicht die Aussage „das
  // Werk hat keinen Verlag", und die will hier niemand treffen.
  bool wants(MetadataField field) => fields == null || fields.contains(field);
  final existingAuthors = summary.authors.isNotEmpty
      ? summary.authors
      : [if (summary.author.trim().isNotEmpty) summary.author.trim()];
  final authors = wants(MetadataField.authors) && candidate.authors.isNotEmpty
      ? candidate.authors
      : existingAuthors;
  final linkOnly = fields != null && fields.isEmpty;
  await library.updateWorkMetadata(
    workId: work.id,
    title: wants(MetadataField.title) ? candidate.title : summary.title,
    authors: authors.isEmpty ? const ['Unbekannt'] : authors,
    subtitle: summary.subtitle,
    series: wants(MetadataField.series)
        ? candidate.series ?? summary.series
        : summary.series,
    seriesSequence: wants(MetadataField.series)
        ? candidate.seriesSequence ?? summary.seriesSequence
        : summary.seriesSequence,
    language: wants(MetadataField.language)
        ? candidate.language ?? summary.language
        : summary.language,
    description: wants(MetadataField.description)
        ? candidate.description ?? summary.description
        : summary.description,
    publisher: wants(MetadataField.publisher)
        ? candidate.publisher ?? summary.publisher
        : summary.publisher,
    publishedYear: wants(MetadataField.year)
        ? candidate.releaseYear ?? summary.publishedYear
        : summary.publishedYear,
    // Einstufung und Stilrichtung sind keine Anzeigefelder, sondern das,
    // wonach die Bibliothek filtert. Sie reisen mit jedem übernommenen
    // Treffer mit — nur beim reinen Verknüpfen bleibt alles, wie es ist.
    contentSensitivity: linkOnly ? null : candidate.contentSensitivity,
    genres: wants(MetadataField.genres) && candidate.genres.isNotEmpty
        ? candidate.genres
        : null,
    contentStyle: linkOnly ? null : candidate.contentStyle,
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
  if (fetchCover &&
      wants(MetadataField.cover) &&
      poster != null &&
      !summary.hasFolderCover) {
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
  if (fetchCover &&
      wants(MetadataField.backdrop) &&
      backdrop != null &&
      summary.backdropPath == null) {
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

  // Wer daran beteiligt war, mit Gesicht.
  //
  // Die Bilder werden geholt und in der Bibliothek abgelegt wie ein Cover:
  // ein Gesicht gehört zum Bestand, und ein Ordner, den man auf ein anderes
  // Gerät trägt, nimmt ihn mit. Ein Bild, das nicht kommt, kostet die
  // Besetzung nicht — dann steht dort ein Platzhalter.
  final people = <({String name, String role, String? imagePath})>[];
  if (candidate.credits.isNotEmpty && !library.isReadOnly) {
    for (final person in candidate.credits) {
      var path = library.personImage(person.name);
      final url = person.imageUrl;
      if (fetchCover && path == null && url != null) {
        final bytes = await fetchCoverBytes(url, client: client);
        if (bytes != null) {
          path = await library.cachePersonImage(
            name: person.name,
            bytes: bytes,
            extension: url.toLowerCase().endsWith('.png') ? 'png' : 'jpg',
          );
        }
      }
      people.add((name: person.name, role: person.role, imagePath: path));
    }
    library.replaceWorkPeople(work.id, people);
  }

  // Ein Podcast bringt die Adresse seines Feeds mit, und nur dort steht,
  // worum es in einer Folge geht. Ein Feed, der nicht antwortet, kostet die
  // Texte — nie den Abgleich.
  var described = 0;
  final feedUrl = candidate.externalIds['feed'];
  if (feedUrl != null || (work.mediaType?.id == 'podcast')) {
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
    peopleFound: people.length,
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
  String? feedUrl,
  http.Client? client,
}) async {
  if (library.isReadOnly) return 0;
  final fromFeed = feedUrl == null
      ? 0
      : await _describeFromFeed(
          library: library,
          workId: workId,
          feedUrl: feedUrl,
          client: client,
        );
  // Ein Ordner enthält oft mehrere Sendungen desselben Hauses — ein Feed
  // kann sie gar nicht alle kennen. Was er nicht beschrieben hat, bringt die
  // Datei meistens selbst mit: jeder Downloader schreibt den Text der Folge
  // in die Tags.
  return fromFeed + await describeFromTags(library: library, workId: workId);
}

/// Nimmt die Texte, die in den Dateien selbst stehen.
///
/// Gefüllt wird nur, was noch leer ist: ein Text aus dem Feed ist der
/// genauere, und ein von Hand gesetzter erst recht.
Future<int> describeFromTags({
  required FundusLibrary library,
  required String workId,
}) async {
  if (library.isReadOnly) return 0;
  const extractor = EmbeddedCoverExtractor();
  final known = library.fileDetails(workId);
  var described = 0;
  for (final track in library.playbackTracks(workId)) {
    if (track.isRemote || track.absolutePath.isEmpty) continue;
    if (known[track.fileId]?.description != null) continue;
    final file = File(track.absolutePath);
    if (!file.existsSync()) continue;
    try {
      final tags = await extractor.extractMetadata(file);
      if (tags.description == null && tags.publishedAt == null) continue;
      library.setFileDetail(
        workId: workId,
        fileId: track.fileId,
        title: known[track.fileId]?.title ?? tags.title,
        description: tags.description,
        publishedAt: known[track.fileId]?.publishedAt ?? tags.publishedAt,
      );
      described++;
    } on Object {
      // Eine Datei, die sich nicht lesen lässt, kostet ihren Text — nicht
      // die der anderen.
      continue;
    }
  }
  return described;
}

Future<int> _describeFromFeed({
  required FundusLibrary library,
  required String workId,
  required String feedUrl,
  http.Client? client,
}) async {
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
