import '../import/abs_importer.dart';

/// One external sidecar disagrees with a value Fundus deliberately protects.
/// The scan never chooses silently; the interface can apply individual fields.
final class MetadataImportConflict {
  const MetadataImportConflict({
    required this.workId,
    required this.workTitle,
    required this.sourcePath,
    required this.source,
    required this.fields,
  });

  final String workId;
  final String workTitle;
  final String sourcePath;
  final WorkMetadataSource source;
  final List<MetadataFieldConflict> fields;
}

final class MetadataFieldConflict {
  const MetadataFieldConflict({
    required this.field,
    required this.currentValue,
    required this.incomingValue,
  });

  final String field;
  final Object? currentValue;
  final Object? incomingValue;
}
