/// A work as another Fundus describes it.
///
/// The identifiers are the peer's own and are kept verbatim. That is the
/// whole point: work and file ids come from the vault's sidecars, so two
/// devices talking about `w-3f9…` mean the same book, and reading positions
/// and marks line up without a translation table that could go wrong.
final class RemoteWorkRecord {
  const RemoteWorkRecord({
    required this.id,
    required this.kind,
    required this.title,
    this.author,
    this.subtitle,
    this.series,
    this.seriesSequence,
    this.hasCover = false,
    this.tags = const [],
    this.metadata = const {},
    this.files = const [],
  });

  final String id;
  final String kind;
  final String title;
  final String? author;
  final String? subtitle;
  final String? series;
  final double? seriesSequence;

  /// Whether the other side can serve a cover for this work.
  final bool hasCover;
  final List<String> tags;
  final Map<String, Object?> metadata;
  final List<RemoteFileRecord> files;
}

/// One file of a remote work.
final class RemoteFileRecord {
  const RemoteFileRecord({
    required this.id,
    required this.filename,
    required this.position,
    this.extension = '',
    this.sizeBytes = 0,
    this.durationMs,
    this.mimeType,
  });

  final String id;
  final String filename;
  final int position;
  final String extension;
  final int sizeBytes;
  final int? durationMs;
  final String? mimeType;
}

/// What one pass of mirroring changed.
final class RemoteMirrorReport {
  const RemoteMirrorReport({required this.written, required this.removed});

  final int written;

  /// Works the other side no longer has. Removed here too — a mirror that
  /// only ever grows stops being a mirror.
  final int removed;
}

/// A peer tried to write a work id that already belongs to another source.
///
/// Work ids are intentionally shared between a vault and its mirrors so that
/// progress can follow a work. They must not, however, be trusted as a
/// globally unique key across independent sources. Until the source relation
/// is split from the portable identity, refusing the write is safer than
/// replacing a local work or another peer's work in place.
final class RemoteWorkIdCollision implements Exception {
  const RemoteWorkIdCollision({
    required this.workId,
    required this.existingSourceId,
    required this.incomingSourceId,
  });

  final String workId;
  final String existingSourceId;
  final String incomingSourceId;

  @override
  String toString() =>
      'Remote work id collision: $workId belongs to '
      '$existingSourceId, cannot mirror into $incomingSourceId.';
}

/// The file id already belongs to another source and must not be replaced.
final class RemoteFileIdCollision implements Exception {
  const RemoteFileIdCollision({
    required this.fileId,
    required this.existingSourceId,
    required this.incomingSourceId,
  });

  final String fileId;
  final String existingSourceId;
  final String incomingSourceId;

  @override
  String toString() =>
      'Remote file id collision: $fileId belongs to '
      '$existingSourceId, cannot mirror into $incomingSourceId.';
}
