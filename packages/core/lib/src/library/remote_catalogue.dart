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
