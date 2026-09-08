import 'dart:typed_data';

import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;

import 'remote_client.dart';

/// Bringing another Fundus's catalogue into this device's own index.
///
/// A phone has no media of its own and never will. What it can have is an
/// index: the works of a machine it is paired with, written into its own
/// tables under a source of their own. Everything above the database then
/// stops caring — one library view, one work screen, one progress table —
/// and origin is a property of the work rather than a second application.
///
/// It is a mirror and not a cache: what the other side no longer has goes
/// away here too. What the *person* did stays — reading positions and marks
/// hang off the work id and survive a work that vanishes for an evening.
final class FundusCatalogueMirror {
  const FundusCatalogueMirror({
    required this.library,
    required this.client,
    required this.libraryId,
    required this.sourceId,
    this.coverLimit = 60,
  });

  final FundusLibrary library;
  final FundusRemoteClient client;

  /// The library over there.
  final String libraryId;

  /// The source row here that its works belong to.
  final String sourceId;

  /// How many covers to fetch in one pass. Covers are the expensive part of
  /// a catalogue and the least urgent: a list with some tiles still blank is
  /// usable, a mirror that takes five minutes is not.
  final int coverLimit;

  /// How many works to ask for in one request.
  ///
  /// The ids travel in the address, so this is bounded by what a URL can
  /// carry rather than by anything about the works themselves.
  static const _batch = 40;

  /// Above this share of the catalogue changed, asking for „everything" is
  /// cheaper than naming what to fetch — the ids alone would be most of the
  /// request.
  static const _fetchAllAbove = 0.6;

  Future<RemoteMirrorReport> run() async {
    // Beim ersten Verbinden gibt es hier noch keinen lokalen Spiegel. Der
    // Index-Hash würde den vollständigen Katalog serverseitig bereits einmal
    // mit allen Dateien aufbauen, nur damit wir ihn direkt danach ein zweites
    // Mal anfordern. Das ist bei großen Bibliotheken unnötig genug, um die
    // Verbindungs-Timeouts zu erreichen. Der Vollabzug ist in diesem Fall die
    // einzige benötigte Antwort; ab dem zweiten Lauf greift der Delta-Index.
    final known = await library.loadMirrorState(sourceId);
    if (known.isEmpty &&
        library
            .listWorks(includeMissing: true)
            .every((work) => work.sourceId != sourceId)) {
      final report = await _full();
      // The server remembers the hashes while producing the full response,
      // so this follow-up is cheap. Persisting them keeps the next run a true
      // delta instead of treating the whole catalogue as new again.
      try {
        await library.saveMirrorState(
          sourceId,
          await client.catalogueIndex(libraryId),
        );
      } on FundusRemoteException catch (error) {
        // Older peers have no index endpoint; their full-catalogue behaviour
        // remains valid, just without the delta optimisation.
        if (error.statusCode != 404) rethrow;
      }
      return report;
    }
    // What the other side holds, as a list of state markers: cheap enough to
    // ask every time, and exact — a hash covers the whole record, so nothing
    // can change without it changing.
    final Map<String, String> index;
    try {
      index = await client.catalogueIndex(libraryId);
    } on FundusRemoteException catch (error) {
      // An older Fundus does not know the index. Fetching everything is what
      // this always did, and it still works.
      if (error.statusCode != 404) rethrow;
      return _full();
    }

    final changed = <String>[
      for (final entry in index.entries)
        if (known[entry.key] != entry.value) entry.key,
    ];
    final vanished = known.keys.where((id) => !index.containsKey(id)).toList();

    if (changed.isEmpty && vanished.isEmpty) {
      // Covers are deliberately fetched in small batches.  An unchanged
      // catalogue still needs another pass when earlier runs stopped at the
      // cover limit; otherwise works after the first batch stay blank forever.
      final needsMoreCovers = library
          .listWorks(includeMissing: true)
          .any((work) => work.sourceId == sourceId && work.coverPath == null);
      if (!needsMoreCovers) {
        return const RemoteMirrorReport(written: 0, removed: 0);
      }
      final works = await client.catalogue(libraryId);
      await _covers(works);
      return const RemoteMirrorReport(written: 0, removed: 0);
    }
    if (changed.length > index.length * _fetchAllAbove) return _full(index);

    // Only the works whose state differs, and — because the mirror removes
    // what the other side no longer has — the ones that are still there.
    final works = <RemoteWorkRecord>[];
    for (var start = 0; start < changed.length; start += _batch) {
      final slice = changed.skip(start).take(_batch);
      works.addAll(await client.catalogue(libraryId, ids: slice));
    }
    final report = library.mirrorRemoteCatalogue(
      sourceId: sourceId,
      works: works,
      // The rest of the catalogue is unchanged, not gone: without this the
      // works that were not fetched would be marked missing.
      keepIds: index.keys.toSet(),
    );
    await library.saveMirrorState(sourceId, index);
    await _covers(works);
    return report;
  }

  /// Fetches the whole catalogue. The first pass, and the answer whenever
  /// most of it has changed anyway.
  Future<RemoteMirrorReport> _full([Map<String, String>? index]) async {
    final works = await client.catalogue(libraryId);
    final report = library.mirrorRemoteCatalogue(
      sourceId: sourceId,
      works: works,
    );
    if (index != null) await library.saveMirrorState(sourceId, index);
    await _covers(works);
    return report;
  }

  /// Fetches covers for works that do not have one here yet.
  ///
  /// One failure is not the end of the pass: a missing cover is a tile with
  /// a placeholder, which is a great deal better than a catalogue that
  /// refuses to finish because one image is broken.
  Future<void> _covers(List<RemoteWorkRecord> works) async {
    final known = {
      for (final work in library.listWorks())
        if (work.coverPath != null) work.id,
    };
    var fetched = 0;
    for (final work in works) {
      if (fetched >= coverLimit) return;
      if (!work.hasCover || known.contains(work.id)) continue;
      final bytes = await _cover(work.id);
      if (bytes == null) continue;
      await library.cacheGeneratedCover(
        workId: work.id,
        bytes: bytes,
        extension: _extensionFor(bytes),
      );
      fetched++;
    }
  }

  Future<Uint8List?> _cover(String workId) async {
    try {
      final response = await client.getBytes(
        '/v1/libraries/$libraryId/works/$workId/cover',
      );
      return response.isEmpty ? null : response;
    } on FundusRemoteException {
      return null;
    } on http.ClientException {
      return null;
    }
  }

  /// PNG and JPEG announce themselves in their first bytes; anything else is
  /// stored as PNG, which is what the cache accepts and what decoders read by
  /// content rather than by name anyway.
  static String _extensionFor(Uint8List bytes) =>
      bytes.length >= 3 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff
      ? 'jpg'
      : 'png';
}
