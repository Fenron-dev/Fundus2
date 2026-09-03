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

  Future<RemoteMirrorReport> run() async {
    final works = await client.catalogue(libraryId);
    final report = library.mirrorRemoteCatalogue(
      sourceId: sourceId,
      works: works,
    );
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
