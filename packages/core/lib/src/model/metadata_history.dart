import 'dart:convert';

/// A metadata value plus its authorship/lock, not a playback snapshot.
/// JSON copying prevents later mutations of an editor's lists from changing
/// what the history says was saved.
final class MetadataFieldState {
  MetadataFieldState({
    required this.present,
    Object? value,
    this.source,
    this.originAt,
    this.locked = false,
  }) : value = _immutableJson(value) {
    if (!present && value != null) {
      throw const FormatException('Ein fehlendes Feld hat keinen Wert.');
    }
    if (source case final origin?) _shortString(origin, 'Herkunft');
    if (utf8.encode(jsonEncode(toJson())).length > 256 * 1024) {
      throw const FormatException('Metadatenfeld ist zu groß.');
    }
  }

  final bool present;
  final Object? value;
  final String? source;
  final DateTime? originAt;
  final bool locked;

  Map<String, Object?> toJson() => {
    'present': present,
    'value': value,
    'source': source,
    'origin_at': originAt?.toUtc().toIso8601String(),
    'locked': locked,
  };

  bool sameAs(MetadataFieldState other) =>
      _canonical(toJson()) == _canonical(other.toJson());

  static MetadataFieldState fromJson(Object? raw) {
    if (raw is! Map ||
        raw['present'] is! bool ||
        raw['locked'] is! bool ||
        (raw['source'] != null && raw['source'] is! String)) {
      throw const FormatException('Ungültiger Metadatenzustand.');
    }
    final at = _optionalDate(raw['origin_at']);
    return MetadataFieldState(
      present: raw['present'] as bool,
      value: raw['value'],
      source: raw['source'] as String?,
      originAt: at,
      locked: raw['locked'] as bool,
    );
  }
}

final class MetadataFieldChange {
  MetadataFieldChange({
    required this.workId,
    required this.field,
    required this.before,
    required this.after,
  }) {
    _shortString(workId, 'Werkkennung');
    if (!isMetadataField(field)) {
      throw const FormatException(
        'Dieses Feld gehört nicht zum Metadatenverlauf.',
      );
    }
  }

  final String workId;
  final String field;
  final MetadataFieldState before, after;
  bool get changed => !before.sameAs(after);

  /// No wildcard import of a work row: positions, annotations, personal votes,
  /// favourites, device credentials and file paths cannot become undo fields.
  static bool isMetadataField(String name) =>
      const {
        'title',
        'author',
        'authors',
        'subtitle',
        'alternate_titles',
        'series',
        'series_sequence',
        'narrators',
        'language',
        'description',
        'publisher',
        'published_year',
        'genres',
        'tags',
        'publication_status',
        'personal_status',
        'kind',
        'content_sensitivity',
        'content_style',
        'external_ids',
        'cover',
        'backdrop',
      }.contains(name) ||
      RegExp(r'^property:[A-Za-z0-9_-]{1,128}$').hasMatch(name);

  Map<String, Object?> toJson() => {
    'work_id': workId,
    'field': field,
    'before': before.toJson(),
    'after': after.toJson(),
  };

  static MetadataFieldChange fromJson(Object? raw) {
    if (raw is! Map || raw['work_id'] is! String || raw['field'] is! String) {
      throw const FormatException('Ungültige Metadatenänderung.');
    }
    return MetadataFieldChange(
      workId: raw['work_id'] as String,
      field: raw['field'] as String,
      before: MetadataFieldState.fromJson(raw['before']),
      after: MetadataFieldState.fromJson(raw['after']),
    );
  }
}

/// One confirmed edit/import, possibly covering many works. Retention drops
/// whole batches, never half of a mass edit that still appears undoable.
final class MetadataChangeBatch {
  MetadataChangeBatch({
    required this.id,
    required this.source,
    required this.at,
    required Iterable<MetadataFieldChange> changes,
    this.reversesBatchId,
  }) : changes = List.unmodifiable(changes.where((change) => change.changed)) {
    _shortString(id, 'Änderungskennung');
    _shortString(source, 'Änderungsquelle');
    if (reversesBatchId case final reversed?) {
      _shortString(reversed, 'Rücknahme');
      if (reversed == id) {
        throw const FormatException(
          'Eine Änderung kann sich nicht selbst zurücknehmen.',
        );
      }
    }
    if (this.changes.length > 50000) {
      throw const FormatException('Zu viele Felder in einer Massenänderung.');
    }
    final keys = <String>{};
    for (final change in this.changes) {
      if (!keys.add('${change.workId}\u0000${change.field}')) {
        throw const FormatException('Doppeltes Feld in einer Massenänderung.');
      }
    }
  }

  final String id, source;
  final DateTime at;
  final String? reversesBatchId;
  final List<MetadataFieldChange> changes;

  Map<String, Object?> toJson() => {
    'id': id,
    'source': source,
    'at': at.toUtc().toIso8601String(),
    'reverses_batch_id': reversesBatchId,
    'changes': changes.map((change) => change.toJson()).toList(),
  };

  static MetadataChangeBatch fromJson(Object? raw) {
    if (raw is! Map ||
        raw['id'] is! String ||
        raw['source'] is! String ||
        raw['changes'] is! List ||
        (raw['changes'] as List).length > 50000 ||
        (raw['reverses_batch_id'] != null &&
            raw['reverses_batch_id'] is! String)) {
      throw const FormatException('Ungültige Massenänderung.');
    }
    final at = _optionalDate(raw['at']);
    if (at == null) throw const FormatException('Änderungszeit fehlt.');
    return MetadataChangeBatch(
      id: raw['id'] as String,
      source: raw['source'] as String,
      at: at,
      reversesBatchId: raw['reverses_batch_id'] as String?,
      changes: (raw['changes'] as List).map(MetadataFieldChange.fromJson),
    );
  }
}

final class MetadataHistory {
  MetadataHistory({Iterable<MetadataChangeBatch> batches = const []})
    : batches = List.unmodifiable(batches) {
    if (this.batches.length > maxBatches ||
        this.batches.map((batch) => batch.id).toSet().length !=
            this.batches.length) {
      throw const FormatException('Ungültiger Metadatenverlauf.');
    }
  }
  static const maxBytes = 32 * 1024 * 1024;
  static const maxBatches = 1000;
  final List<MetadataChangeBatch> batches;

  /// Idempotent retries are safe. Reusing an id for different changes is not.
  MetadataHistory append(
    MetadataChangeBatch batch, {
    int retainBatches = 100,
    int byteBudget = 16 * 1024 * 1024,
  }) {
    if (retainBatches < 1 ||
        retainBatches > maxBatches ||
        byteBudget < 1 ||
        byteBudget > maxBytes) {
      throw ArgumentError('Ungültige Aufbewahrungsgrenze.');
    }
    final existing = batches.where((value) => value.id == batch.id).firstOrNull;
    if (existing != null) {
      if (_canonical(existing.toJson()) != _canonical(batch.toJson())) {
        throw const FormatException('Änderungskennung bereits anders belegt.');
      }
      return this;
    }
    if (batch.changes.isEmpty) return this;
    final kept = [...batches, batch];
    while (kept.length > retainBatches) {
      kept.removeAt(0);
    }
    // Encode each batch once, not the whole history again for every pruned
    // batch. Large mass edits must not turn retention into quadratic JSON work.
    final sizes = [
      for (final value in kept) utf8.encode(jsonEncode(value.toJson())).length,
    ];
    var bytes =
        utf8.encode(MetadataHistory().encode()).length + kept.length - 1;
    for (final size in sizes) {
      bytes += size;
    }
    var start = 0;
    while (bytes > byteBudget && start < kept.length - 1) {
      bytes -= sizes[start++] + 1; // One comma disappears with an old batch.
    }
    if (bytes > byteBudget) {
      throw const FormatException(
        'Diese Massenänderung überschreitet das Verlaufsbudget.',
      );
    }
    return MetadataHistory(batches: kept.skip(start));
  }

  String encode() => jsonEncode({
    'format_version': 1,
    'batches': batches.map((batch) => batch.toJson()).toList(),
  });

  static MetadataHistory decode(String encoded) {
    if (utf8.encode(encoded).length > maxBytes) {
      throw const FormatException('Metadatenverlauf ist zu groß.');
    }
    final raw = jsonDecode(encoded);
    if (raw is! Map ||
        raw['format_version'] != 1 ||
        raw['batches'] is! List ||
        (raw['batches'] as List).length > maxBatches) {
      throw const FormatException('Nicht unterstützter Metadatenverlauf.');
    }
    return MetadataHistory(
      batches: (raw['batches'] as List).map(MetadataChangeBatch.fromJson),
    );
  }
}

enum MetadataUndoConflictReason { changedSince }

final class MetadataUndoConflict {
  const MetadataUndoConflict(this.change, this.reason);
  final MetadataFieldChange change;
  final MetadataUndoConflictReason reason;
}

/// A preview, not permission to write. The writer must recalculate inside its
/// transaction immediately before applying. Null means hidden/missing: never
/// offer its prior contents in a visible preview.
final class MetadataUndoPlan {
  MetadataUndoPlan._(this.applicable, this.conflicts);
  final List<MetadataFieldChange> applicable;
  final List<MetadataUndoConflict> conflicts;

  static MetadataUndoPlan preview({
    required MetadataChangeBatch batch,
    required MetadataFieldState? Function(String workId, String field) current,
    bool Function(MetadataFieldChange change)? selected,
  }) {
    final applicable = <MetadataFieldChange>[];
    final conflicts = <MetadataUndoConflict>[];
    for (final change in batch.changes) {
      if (selected != null && !selected(change)) continue;
      final now = current(change.workId, change.field);
      if (now == null) {
        // A hidden/missing work must not expose its previous field values.
        continue;
      }
      if (!now.sameAs(change.after)) {
        conflicts.add(
          MetadataUndoConflict(change, MetadataUndoConflictReason.changedSince),
        );
      } else {
        applicable.add(change);
      }
    }
    return MetadataUndoPlan._(
      List.unmodifiable(applicable),
      List.unmodifiable(conflicts),
    );
  }
}

void _shortString(String value, String label) {
  if (value.trim().isEmpty || value.length > 512 || value.contains('\u0000')) {
    throw FormatException('$label ist ungültig.');
  }
}

DateTime? _optionalDate(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const FormatException('Ungültiger Zeitpunkt.');
  final result = DateTime.tryParse(value);
  if (result == null) throw const FormatException('Ungültiger Zeitpunkt.');
  return result.toUtc();
}

Object? _immutableJson(Object? value, [int depth = 0]) {
  if (depth > 16) {
    throw const FormatException('Zu tief verschachtelter Metadatenwert.');
  }
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is List) {
    return List<Object?>.unmodifiable(
      value.map((item) => _immutableJson(item, depth + 1)),
    );
  }
  if (value is Map && value.keys.every((key) => key is String)) {
    return Map<String, Object?>.unmodifiable({
      for (final key in value.keys.cast<String>())
        key: _immutableJson(value[key], depth + 1),
    });
  }
  throw const FormatException('Metadatenwert ist kein endlicher JSON-Wert.');
}

String _canonical(Object? value) {
  Object? ordered(Object? raw) {
    if (raw is Map) {
      final keys = raw.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: ordered(raw[key])};
    }
    if (raw is List) return raw.map(ordered).toList();
    return raw;
  }

  return jsonEncode(ordered(value));
}
