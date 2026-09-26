import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;

import 'metadata_http_client.dart';

import '../app/fundus_log.dart';
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
  tags('Tags'),
  description('Beschreibung'),
  cover('Titelbild'),
  backdrop('Breitbild');

  const MetadataField(this.label);

  final String label;
}

enum MetadataMergeMode { complement, replace }

/// A picked match together with what of it should be written.
///
/// An empty [fields] is „nur verknüpfen": the work remembers where it was
/// found — the id at the service, a podcast's feed — and not one visible
/// field changes. That is what makes a later, deliberate match possible
/// without touching anything today.
final class MetadataChoice {
  const MetadataChoice({
    required this.candidate,
    this.fields,
    this.mergeMode = MetadataMergeMode.complement,
    this.useIncomingCover = false,
  });

  final MetadataCandidate candidate;

  /// `null` means everything the match knows.
  final Set<MetadataField>? fields;
  final MetadataMergeMode mergeMode;
  final bool useIncomingCover;

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
    this.coverFailure,
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
  final String? coverFailure;

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
  // Keep the programmatic API backwards compatible: callers that do not
  // show the merge chooser retain the historical replace behaviour. The
  // metadata dialog passes the user's explicit choice (complement is its
  // default).
  MetadataMergeMode mergeMode = MetadataMergeMode.replace,
  bool forceReplace = false,
  bool useIncomingCover = false,
}) async {
  final summary = work.summary;
  // Was nicht gewählt wurde, bekommt seinen bisherigen Wert zurück — nicht
  // `null`. Ein leeres Feld ist für die Metadatenschicht die Aussage „das
  // Werk hat keinen Verlag", und die will hier niemand treffen.
  bool wants(MetadataField field) => fields == null || fields.contains(field);
  bool hasValue(MetadataField field) => switch (field) {
    MetadataField.title => summary.title.trim().isNotEmpty,
    MetadataField.authors =>
      summary.authors.isNotEmpty || summary.author.trim().isNotEmpty,
    MetadataField.series => summary.series?.trim().isNotEmpty ?? false,
    MetadataField.year => summary.publishedYear != null,
    MetadataField.publisher => summary.publisher?.trim().isNotEmpty ?? false,
    MetadataField.language => summary.language?.trim().isNotEmpty ?? false,
    MetadataField.genres => summary.genres.isNotEmpty,
    MetadataField.tags => library.loadAnnotations(work.id).tags.isNotEmpty,
    MetadataField.description =>
      summary.description?.trim().isNotEmpty ?? false,
    MetadataField.cover => summary.coverPath != null,
    MetadataField.backdrop => summary.backdropPath != null,
  };
  bool accepts(MetadataField field) =>
      wants(field) &&
      (mergeMode == MetadataMergeMode.replace || !hasValue(field));
  final existingAuthors = summary.authors.isNotEmpty
      ? summary.authors
      : [if (summary.author.trim().isNotEmpty) summary.author.trim()];
  final authors = !wants(MetadataField.authors) || candidate.authors.isEmpty
      ? existingAuthors
      : mergeMode == MetadataMergeMode.complement
      ? {...existingAuthors, ...candidate.authors}.toList(growable: false)
      : candidate.authors;
  final alternateTitles = !wants(MetadataField.title)
      ? summary.alternateTitles
      : mergeMode == MetadataMergeMode.complement
      ? {
          ...summary.alternateTitles,
          ...candidate.alternateTitles,
        }.where((title) => title != summary.title).toList(growable: false)
      : candidate.alternateTitles;
  final linkOnly = fields != null && fields.isEmpty;
  await library.updateWorkMetadata(
    workId: work.id,
    title: accepts(MetadataField.title) ? candidate.title : summary.title,
    authors: authors.isEmpty ? const ['Unbekannt'] : authors,
    subtitle: summary.subtitle,
    alternateTitles: alternateTitles,
    series: accepts(MetadataField.series)
        ? candidate.series ?? summary.series
        : summary.series,
    seriesSequence: wants(MetadataField.series)
        ? candidate.seriesSequence ?? summary.seriesSequence
        : summary.seriesSequence,
    language: accepts(MetadataField.language)
        ? candidate.language ?? summary.language
        : summary.language,
    description: accepts(MetadataField.description)
        ? candidate.description ?? summary.description
        : summary.description,
    publisher: accepts(MetadataField.publisher)
        ? candidate.publisher ?? summary.publisher
        : summary.publisher,
    publishedYear: accepts(MetadataField.year)
        ? candidate.releaseYear ?? summary.publishedYear
        : summary.publishedYear,
    // Einstufung und Stilrichtung sind keine Anzeigefelder, sondern das,
    // wonach die Bibliothek filtert. Sie reisen mit jedem übernommenen
    // Treffer mit — nur beim reinen Verknüpfen bleibt alles, wie es ist.
    contentSensitivity: linkOnly ? null : candidate.contentSensitivity,
    genres: !wants(MetadataField.genres) || candidate.genres.isEmpty
        ? null
        : mergeMode == MetadataMergeMode.complement
        ? {...summary.genres, ...candidate.genres}.toList(growable: false)
        : candidate.genres,
    contentStyle: linkOnly ? null : candidate.contentStyle,
    // Woher der Treffer kam — bei einem Podcast steckt darin die Adresse des
    // Feeds, und der Feed ist das Einzige, was etwas über die einzelnen
    // Folgen weiß.
    externalIds: candidate.externalIds.isEmpty ? null : candidate.externalIds,
    // Written as what it is: an answer from a service. The metadata layer
    // ranks a value someone typed above one a service gave, which is what
    // makes a correction survive the next match.
    source: WorkMetadataSource.online,
    force: forceReplace && mergeMode == MetadataMergeMode.replace,
  );
  if (candidate.publicationStatus != null &&
      (mergeMode == MetadataMergeMode.replace ||
          summary.publicationStatus == 'unknown')) {
    await library.setWorkStatuses(
      workId: work.id,
      publicationStatus: candidate.publicationStatus,
    );
  }
  if (!linkOnly && wants(MetadataField.tags) && candidate.tags.isNotEmpty) {
    final current = library.loadAnnotations(work.id).tags;
    await library.replaceWorkTags(
      work.id,
      mergeMode == MetadataMergeMode.complement
          ? {...current, ...candidate.tags}
          : candidate.tags,
    );
  }
  if (!linkOnly && candidate.sourceRating != null) {
    final mediaKind = work.mediaType?.id ?? candidate.workKind ?? '';
    final wantedName = candidate.provider == 'tmdb'
        ? 'TMDB-Wertung'
        : '${candidate.provider.toUpperCase()}-Wertung';
    final definitions = library.listPropertyDefinitions(mediaKind: mediaKind);
    final named = definitions
        .where((entry) => entry.name.toLowerCase() == wantedName.toLowerCase())
        .firstOrNull;
    // A user may already have created a five-star field with this name. An
    // online match must never silently change its type to a 0–10 number.
    final definition = named?.valueType == PropertyValueType.number
        ? named!
        : await library.savePropertyDefinition(
            mediaKind: mediaKind,
            name: named == null ? wantedName : '$wantedName (0–10)',
            valueType: PropertyValueType.number,
          );
    final values = library.loadWorkProperties(work.id);
    if (mergeMode == MetadataMergeMode.replace ||
        !values.containsKey(definition.id)) {
      await library.setWorkProperty(
        workId: work.id,
        definitionId: definition.id,
        value: candidate.sourceRating!,
        source: candidate.provider,
      );
    }
  }

  var fetched = false;
  var failed = false;
  String? coverFailure;
  final poster = candidate.posterUrl;
  // A `cover.jpg` in the folder is somebody's decision and is left alone. A
  // picture Fundus fetched earlier is not — it was the best answer at the
  // time, and this match is a newer one. Testing only for "has a cover at
  // all" meant a work that once got a picture could never get a better one,
  // and one whose first attempt failed stayed blank for good.
  if (fetchCover &&
      wants(MetadataField.cover) &&
      (accepts(MetadataField.cover) || useIncomingCover) &&
      poster != null &&
      (!summary.hasFolderCover || useIncomingCover)) {
    final download = await _fetchCover(poster, client: client);
    if (download.bytes == null) {
      failed = true;
      coverFailure = download.failure;
    } else {
      await library.cacheGeneratedCover(
        workId: work.id,
        bytes: download.bytes!,
        extension: poster.toLowerCase().endsWith('.png') ? 'png' : 'jpg',
      );
      if (useIncomingCover) {
        library.setCoverPreference(work.id, generated: true);
      }
      fetched = true;
    }
  }
  // The wide picture is the one the stage and the head of a detail page
  // need, and no folder ever holds one — so unlike the cover it is fetched
  // whenever the match offers it and the work has none.
  var wide = false;
  final backdrop = candidate.backdropUrl;
  if (fetchCover &&
      accepts(MetadataField.backdrop) &&
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
      people.add((
        name: person.name,
        role: person.roleGroup ?? person.role,
        imagePath: path,
      ));
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
    coverFailure: coverFailure,
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
  return (await _fetchCover(url, client: client)).bytes;
}

final class _CoverDownload {
  const _CoverDownload({this.bytes, this.failure});

  final Uint8List? bytes;
  final String? failure;
}

Future<_CoverDownload> _fetchCover(String url, {http.Client? client}) async {
  final own = client == null;
  final fetcher = client ?? createMetadataHttpClient();
  try {
    final response = await fetcher
        .get(
          Uri.parse(url),
          headers: const {
            'accept': 'image/avif,image/webp,image/jpeg,image/png,*/*',
            'user-agent': 'Fundus/2',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return _coverFailure(url, 'HTTP ${response.statusCode}');
    }
    if (response.bodyBytes.isEmpty) {
      return _coverFailure(url, 'leere Antwort');
    }
    return _CoverDownload(bytes: response.bodyBytes);
  } on WindowsMetadataException catch (error) {
    return _coverFailure(url, error.toString());
  } on HandshakeException {
    return _coverFailure(url, 'TLS-Zertifikat konnte nicht geprüft werden');
  } on TimeoutException {
    return _coverFailure(url, 'Zeitüberschreitung beim Bildabruf');
  } on SocketException {
    return _coverFailure(url, 'Bildserver nicht erreichbar');
  } on FormatException {
    return _coverFailure(url, 'ungültige Bildadresse');
  } on Object catch (error) {
    return _coverFailure(url, 'Abruf fehlgeschlagen (${error.runtimeType})');
  } finally {
    if (own) fetcher.close();
  }
}

_CoverDownload _coverFailure(String url, String reason) {
  final host = Uri.tryParse(url)?.host;
  FundusLog.instance.warn('metadata.image', {
    if (host != null && host.isNotEmpty) 'host': host,
    'error': reason,
  });
  return _CoverDownload(failure: reason);
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
