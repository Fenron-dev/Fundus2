enum MediaPositionKind { time, page, epubCfi, imageIndex }

/// Which of two positions is further along in the same work.
///
/// A page number alone cannot answer this. A manga is a folder of chapters,
/// each numbered from page one, so page 5 of chapter 1 looks bigger than page
/// 1 of chapter 2 while being an hour behind it. What decides is first which
/// file the position sits in and only then how far into it — and the order of
/// the files is something only the work knows, which is why it has to be
/// passed in.
///
/// [fileOrder] is the work's content files, in playing order. A position
/// whose file is not in the list is treated as the first one: better to
/// compare by page than to call it further than everything.
///
/// Returns a negative number when [left] is behind [right], zero when they
/// are level, and a positive number when it is ahead.
int comparePositions(
  MediaPosition left,
  MediaPosition right, {
  List<String> fileOrder = const [],
}) {
  int place(MediaPosition position) {
    final fileId = position.fileId;
    if (fileId == null) return 0;
    final index = fileOrder.indexOf(fileId);
    return index < 0 ? 0 : index;
  }

  final byFile = place(left).compareTo(place(right));
  if (byFile != 0) return byFile;
  final byValue = (left.numericValue ?? 0).compareTo(right.numericValue ?? 0);
  if (byValue != 0) return byValue;
  // Two positions on the same page: whoever is further down it.
  return (left.scrollOffset ?? 0).compareTo(right.scrollOffset ?? 0);
}

final class MediaPosition {
  const MediaPosition({
    required this.kind,
    this.schemaVersion = currentSchemaVersion,
    this.numericValue,
    this.key,
    this.total,
    this.fileId,
    this.chapterId,
    this.elementId,
    this.scrollOffset,
    this.label,
  }) : assert(numericValue != null || key != null),
       assert(schemaVersion > 0 && schemaVersion <= currentSchemaVersion),
       assert(scrollOffset == null || scrollOffset >= 0 && scrollOffset <= 1);

  static const currentSchemaVersion = 2;

  final MediaPositionKind kind;
  final int schemaVersion;
  final double? numericValue;
  final String? key;
  final double? total;
  final String? fileId;
  final String? chapterId;
  final String? elementId;

  /// Normalized position inside a continuous page or chapter (0..1).
  final double? scrollOffset;
  final String? label;

  double? get fraction {
    final value = numericValue;
    final maximum = total;
    if (value == null || maximum == null || maximum <= 0) return null;
    return (value / maximum).clamp(0, 1);
  }

  String get displayValue {
    return switch (kind) {
      MediaPositionKind.time => _formatDuration(numericValue ?? 0),
      MediaPositionKind.page => 'Seite ${(numericValue ?? 0).round()}',
      MediaPositionKind.imageIndex => 'Bild ${(numericValue ?? 0).round()}',
      MediaPositionKind.epubCfi => label ?? 'EPUB-Position',
    };
  }

  MediaPosition withFileId(String? value) => MediaPosition(
    kind: kind,
    schemaVersion: schemaVersion,
    numericValue: numericValue,
    key: key,
    total: total,
    fileId: value,
    chapterId: chapterId,
    elementId: elementId,
    scrollOffset: scrollOffset,
    label: label,
  );

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'kind': kind.name,
    'numeric_value': numericValue,
    'key': key,
    'total': total,
    'file_id': fileId,
    'chapter_id': chapterId,
    'element_id': elementId,
    'scroll_offset': scrollOffset,
    'label': label,
  };

  factory MediaPosition.fromJson(Map<String, Object?> json) {
    final version = json['schema_version'] as int? ?? 1;
    if (version < 1 || version > currentSchemaVersion) {
      throw FormatException('Nicht unterstützte Positionsversion: $version.');
    }
    final scrollOffset = (json['scroll_offset'] as num?)?.toDouble();
    if (scrollOffset != null &&
        (!scrollOffset.isFinite || scrollOffset < 0 || scrollOffset > 1)) {
      throw const FormatException('Ungültiger normalisierter Scroll-Offset.');
    }
    return MediaPosition(
      schemaVersion: version,
      kind: MediaPositionKind.values.byName(json['kind']! as String),
      numericValue: (json['numeric_value'] as num?)?.toDouble(),
      key: json['key'] as String?,
      total: (json['total'] as num?)?.toDouble(),
      fileId: json['file_id'] as String?,
      chapterId: json['chapter_id'] as String?,
      elementId: json['element_id'] as String?,
      scrollOffset: scrollOffset,
      label: json['label'] as String?,
    );
  }

  static String _formatDuration(double seconds) {
    final duration = Duration(milliseconds: (seconds * 1000).round());
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final remaining = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$remaining';
  }
}
