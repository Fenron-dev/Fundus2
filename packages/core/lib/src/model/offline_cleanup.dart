import '../playback/library_playback.dart';

/// Selection only, never deletion authority. "Before my position" is not
/// evidence of consumption: skipped chapters stay unless explicitly finished.
abstract final class OfflineCleanup {
  static Set<String> candidates({
    required bool checkpointConfirmed,
    required List<LibraryPlaybackTrack> tracks,
    required Set<String> finishedFileIds,
    required Set<String> offlineFileIds,
    required String? currentFileId,
    required bool currentFileFinished,
    required int nextFiles,
    Set<String> inUse = const {},
  }) {
    if (!checkpointConfirmed || currentFileId == null || nextFiles < 1) {
      return const {};
    }
    final start = tracks.indexWhere((track) => track.fileId == currentFileId);
    if (start < 0) return const {};
    final keep = <String>{...inUse};
    if (!currentFileFinished) keep.add(currentFileId);
    final distinct = <String>{};
    keep.addAll(
      tracks
          .skip(start + (currentFileFinished ? 1 : 0))
          .where(
            (track) =>
                !finishedFileIds.contains(track.fileId) ||
                (track.fileId == currentFileId && !currentFileFinished),
          )
          .where((track) => distinct.add(track.fileId))
          .take(nextFiles)
          .map((track) => track.fileId),
    );
    return {
      for (final track in tracks)
        if (offlineFileIds.contains(track.fileId) &&
            finishedFileIds.contains(track.fileId) &&
            !keep.contains(track.fileId))
          track.fileId,
    };
  }
}
