import '../model/media_position.dart';
import '../scan/audio_technical_metadata.dart';
import '../video/video_metadata.dart';

final class LibraryPlaybackTrack {
  const LibraryPlaybackTrack({
    required this.fileId,
    required this.relativePath,
    required this.absolutePath,
    required this.title,
    this.sourceId = 'local',
    required this.index,
    this.duration,
    this.audioMetadata,
    this.episode,
  });

  final String fileId;
  final String relativePath;

  /// Empty for a file that is not on this device — see [sourceId].
  final String absolutePath;

  /// Which source the bytes belong to. `local` is the vault itself; anything
  /// else is another Fundus, and [absolutePath] is then empty.
  final String sourceId;
  final String title;

  bool get isRemote => sourceId != 'local';
  final int index;
  final Duration? duration;
  final AudioTechnicalMetadata? audioMetadata;
  final VideoEpisodeIdentity? episode;
}

final class LibraryPlaybackChapter {
  const LibraryPlaybackChapter({
    required this.title,
    required this.fileId,
    required this.trackIndex,
    required this.position,
    this.duration,
  });

  final String title;
  final String fileId;
  final int trackIndex;
  final Duration position;
  final Duration? duration;
}

final class LibraryPlaybackProgress {
  const LibraryPlaybackProgress({
    required this.workId,
    required this.fileId,
    required this.position,
    required this.finished,
    required this.revision,
    required this.updatedAt,
    this.deviceId = 'unknown',
    this.operationId,
  });

  final String workId;
  final String? fileId;
  final MediaPosition position;
  final bool finished;
  final int revision;
  final DateTime updatedAt;
  final String deviceId;
  final String? operationId;
}

/// A position from somewhere else that was not taken.
///
/// Kept so it can be offered when the work is opened, rather than being the
/// thing that silently happened to someone's evening.
final class LibraryProgressChoice {
  const LibraryProgressChoice({
    required this.workId,
    required this.position,
    required this.fileId,
    required this.finished,
    required this.deviceId,
    required this.deviceName,
    required this.updatedAt,
    required this.recordedAt,
    this.userId = 'default',
  });

  final String workId;
  final MediaPosition position;
  final String? fileId;
  final bool finished;

  /// Which device wrote it, and what that device calls itself. The id alone
  /// says nothing to a person; the name is what makes the question answerable.
  final String deviceId;
  final String deviceName;

  /// The account the position belongs to. One row per user, so two people
  /// sharing a device are never offered each other's place.
  final String userId;

  final DateTime updatedAt;
  final DateTime recordedAt;

  /// What to call the side it came from.
  String get origin => deviceName.trim().isEmpty ? deviceId : deviceName.trim();
}

final class LibraryPlaybackRevision {
  const LibraryPlaybackRevision({
    required this.workId,
    required this.fileId,
    required this.position,
    required this.finished,
    required this.revision,
    required this.createdAt,
    required this.deviceId,
    required this.operationId,
  });

  final String workId;
  final String? fileId;
  final MediaPosition position;
  final bool finished;
  final int revision;
  final DateTime createdAt;
  final String deviceId;
  final String operationId;
}
