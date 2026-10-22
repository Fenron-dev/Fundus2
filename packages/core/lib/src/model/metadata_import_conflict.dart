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

  Map<String, Object?> toJson() => {
    'work_id': workId,
    'work_title': workTitle,
    'source_path': sourcePath,
    'source': source.name,
    'fields': [
      for (final field in fields)
        {
          'field': field.field,
          'current': field.currentValue,
          'incoming': field.incomingValue,
        },
    ],
  };

  static MetadataImportConflict? fromJson(Object? value) {
    if (value is! Map ||
        value['work_id'] is! String ||
        value['work_title'] is! String ||
        value['source_path'] is! String ||
        value['fields'] is! List) {
      return null;
    }
    final source = WorkMetadataSource.values
        .where((item) => item.name == value['source'])
        .firstOrNull;
    if (source == null) return null;
    return MetadataImportConflict(
      workId: value['work_id'] as String,
      workTitle: value['work_title'] as String,
      sourcePath: value['source_path'] as String,
      source: source,
      fields: [
        for (final raw in value['fields'] as List)
          if (raw is Map && raw['field'] is String)
            MetadataFieldConflict(
              field: raw['field'] as String,
              currentValue: raw['current'],
              incomingValue: raw['incoming'],
            ),
      ],
    );
  }
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
