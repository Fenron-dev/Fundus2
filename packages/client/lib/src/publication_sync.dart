import 'package:fundus_core/fundus_core.dart';

import 'remote_client.dart';

/// Runs at subscription/catalogue boundaries, never while building a list.
/// Each peer owns its metadata; no mirrored source is relayed through a host.
Future<Set<String>> hydratePublicationManifests({
  required FundusLibrary library,
  required FundusRemoteClient client,
  required String sourceId,
  required String libraryId,
  Set<String>? workIds,
  bool tolerateTransientFailure = false,
}) async {
  final targets = workIds ?? library.contentSubscriptions;
  final deferred = <String>{};
  for (final workId in targets) {
    final work = library.workSummary(workId);
    if (work == null || work.sourceId != sourceId) continue;
    for (final file in library.playbackTracks(workId)) {
      if (!file.title.toLowerCase().endsWith('.epub') ||
          library.cachedPublicationManifest(file.fileId) != null) {
        continue;
      }
      try {
        if (!await client.supportsPublicationManifests()) return deferred;
        final manifest = await client.publicationManifest(
          libraryId,
          file.fileId,
        );
        library.saveRemotePublicationManifest(
          file.fileId,
          manifest ??
              PublicationManifest(
                fileRevision: '${file.sizeBytes}:${file.contentRevision}',
                units: const [],
                supported: false,
              ),
        );
      } on FundusRemoteException catch (error) {
        if (!tolerateTransientFailure ||
            (!error.isTransient && error.statusCode != 413)) {
          rethrow;
        }
        deferred.add(workId);
        break;
      } on StateError {
        // Catalogue and file may have changed while the manifest was fetched.
        if (!tolerateTransientFailure) rethrow;
        deferred.add(workId);
        break;
      } on FormatException {
        if (!tolerateTransientFailure) rethrow;
        deferred.add(workId);
        break;
      }
    }
  }
  return deferred;
}
