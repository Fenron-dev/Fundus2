enum LibraryPlaylistKind { manual, smart, series }

/// One line in a list.
///
/// A list holds works — and, where somebody picked one, a single file inside
/// a work. Music is the reason: an album is one work with a dozen tracks, and
/// a playlist of albums is not what anybody means by a playlist. A reading
/// list, by contrast, is almost always whole works, and there [fileId] stays
/// empty.
final class PlaylistEntry {
  const PlaylistEntry(this.workId, {this.fileId});

  final String workId;
  final String? fileId;

  @override
  bool operator ==(Object other) =>
      other is PlaylistEntry &&
      other.workId == workId &&
      other.fileId == fileId;

  @override
  int get hashCode => Object.hash(workId, fileId);

  @override
  String toString() => fileId == null
      ? 'PlaylistEntry($workId)'
      : 'PlaylistEntry($workId/$fileId)';
}

final class LibraryPlaylist {
  const LibraryPlaylist({
    required this.id,
    required this.name,
    required this.kind,
    this.mediaType,
    required this.entries,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final LibraryPlaylistKind kind;
  final String? mediaType;
  final List<PlaylistEntry> entries;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The works in the list, in order and with repeats — what a peer that
  /// only knows works is told, and what a permission check asks about.
  List<String> get workIds => [for (final entry in entries) entry.workId];
}
