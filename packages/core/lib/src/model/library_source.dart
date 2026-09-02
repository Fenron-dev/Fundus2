/// Where a catalogue came from.
///
/// The locally opened vault is a source like any other — that is the whole
/// point. Without this row the client would need one code path for "my disk"
/// and another for "a server", which is exactly the split that made the
/// previous client grow two parallel user interfaces.
enum LibrarySourceKind {
  vault,
  peer;

  static LibrarySourceKind parse(String value) =>
      value == 'peer' ? LibrarySourceKind.peer : LibrarySourceKind.vault;
}

/// Whether the source answered recently.
enum LibrarySourceStatus {
  available,
  unreachable,
  unknown;

  static LibrarySourceStatus parse(String value) => switch (value) {
    'available' => LibrarySourceStatus.available,
    'unreachable' => LibrarySourceStatus.unreachable,
    _ => LibrarySourceStatus.unknown,
  };
}

final class LibrarySource {
  const LibrarySource({
    required this.id,
    required this.kind,
    required this.displayName,
    this.libraryId = '',
    this.vaultPath,
    this.baseUrl,
    this.certificatePin,
    this.syncCursor = 0,
    this.status = LibrarySourceStatus.unknown,
    this.lastSeenAt,
  });

  final String id;
  final LibrarySourceKind kind;
  final String displayName;

  /// The identifier from the source's own manifest. It survives a moved
  /// drive letter or mount point, which is how a vault is recognised again
  /// after it reappears somewhere else.
  final String libraryId;

  /// Only for [LibrarySourceKind.vault]: resolved on this device, never
  /// synchronised — an absolute path means nothing on the next device.
  final String? vaultPath;

  /// Only for [LibrarySourceKind.peer].
  final String? baseUrl;
  final String? certificatePin;

  /// How far the catalogue delta has been consumed.
  final int syncCursor;

  final LibrarySourceStatus status;
  final DateTime? lastSeenAt;

  bool get isVault => kind == LibrarySourceKind.vault;

  LibrarySource copyWith({
    String? displayName,
    String? libraryId,
    String? vaultPath,
    String? baseUrl,
    String? certificatePin,
    int? syncCursor,
    LibrarySourceStatus? status,
    DateTime? lastSeenAt,
  }) => LibrarySource(
    id: id,
    kind: kind,
    displayName: displayName ?? this.displayName,
    libraryId: libraryId ?? this.libraryId,
    vaultPath: vaultPath ?? this.vaultPath,
    baseUrl: baseUrl ?? this.baseUrl,
    certificatePin: certificatePin ?? this.certificatePin,
    syncCursor: syncCursor ?? this.syncCursor,
    status: status ?? this.status,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
  );
}
