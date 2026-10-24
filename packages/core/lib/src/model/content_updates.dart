import 'dart:convert';

enum ContentUpdateKind { added, changed, removed }

enum ContentUpdateDisposition { unread, later, seen, hidden }

/// Indexed file identity, not a filesystem probe or a reading position.
final class ContentUpdateFile {
  const ContentUpdateFile({
    required this.workId,
    required this.key,
    required this.fileId,
    required this.title,
    required this.revision,
  });

  final String workId;
  final String key;
  final String fileId;
  final String title;
  final String revision;

  Map<String, Object?> toJson() => {
    'work_id': workId,
    'key': key,
    'file_id': fileId,
    'title': title,
    'revision': revision,
  };

  static ContentUpdateFile fromJson(Object? raw) {
    if (raw is! Map ||
        [
          'work_id',
          'key',
          'file_id',
          'title',
          'revision',
        ].any((key) => raw[key] is! String)) {
      throw const FormatException('Ungültiger Inhaltsstand.');
    }
    return ContentUpdateFile(
      workId: raw['work_id'] as String,
      key: raw['key'] as String,
      fileId: raw['file_id'] as String,
      title: raw['title'] as String,
      revision: raw['revision'] as String,
    );
  }
}

final class ContentUpdateEvent {
  const ContentUpdateEvent({
    required this.id,
    required this.file,
    required this.kind,
    required this.detectedAt,
    this.disposition = ContentUpdateDisposition.unread,
  });

  final String id;
  final ContentUpdateFile file;
  final ContentUpdateKind kind;
  final DateTime detectedAt;
  final ContentUpdateDisposition disposition;

  ContentUpdateEvent withDisposition(ContentUpdateDisposition value) =>
      ContentUpdateEvent(
        id: id,
        file: file,
        kind: kind,
        detectedAt: detectedAt,
        disposition: value,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'file': file.toJson(),
    'kind': kind.name,
    'detected_at': detectedAt.toUtc().toIso8601String(),
    'disposition': disposition.name,
  };

  static ContentUpdateEvent fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) {
      throw const FormatException('Ungültiger Inhaltshinweis.');
    }
    final kind = ContentUpdateKind.values
        .where((value) => value.name == raw['kind'])
        .firstOrNull;
    final disposition = ContentUpdateDisposition.values
        .where((value) => value.name == raw['disposition'])
        .firstOrNull;
    final date = raw['detected_at'] is String
        ? DateTime.tryParse(raw['detected_at'] as String)
        : null;
    if (kind == null || disposition == null || date == null) {
      throw const FormatException('Ungültiger Inhaltshinweis.');
    }
    return ContentUpdateEvent(
      id: raw['id'] as String,
      file: ContentUpdateFile.fromJson(raw['file']),
      kind: kind,
      detectedAt: date,
      disposition: disposition,
    );
  }
}

/// Portable, versioned inbox. Baselines belong to subscriptions, not unread
/// progress. Rebuilding only the SQLite index therefore cannot create a flood
/// of historical "new chapters". Mutations happen before any asynchronous I/O.
final class ContentUpdates {
  ContentUpdates();

  final Map<String, Map<String, ContentUpdateFile>> _baselines = {};
  final List<ContentUpdateEvent> _events = [];
  int _sequence = 0;

  Set<String> get subscriptions => Set.unmodifiable(_baselines.keys);
  List<ContentUpdateEvent> get events => List.unmodifiable(_events.reversed);

  void subscribe(String workId, Iterable<ContentUpdateFile> files) {
    // Repeatedly subscribing must not acknowledge or reset pending changes.
    _baselines.putIfAbsent(
      workId,
      () => {for (final file in files) file.key: file},
    );
  }

  void unsubscribe(String workId) => _baselines.remove(workId);

  bool reconcile(Iterable<ContentUpdateFile> files, {DateTime? now}) {
    final current = <String, Map<String, ContentUpdateFile>>{
      for (final id in _baselines.keys) id: {},
    };
    for (final file in files) {
      current[file.workId]?[file.key] = file;
    }
    var changed = false;
    final detectedAt = (now ?? DateTime.now()).toUtc();
    for (final entry in current.entries) {
      final previous = _baselines[entry.key]!;
      void record(ContentUpdateFile file, ContentUpdateKind kind) {
        _sequence++;
        _events.add(
          ContentUpdateEvent(
            id: base64Url.encode(
              utf8.encode('${file.workId}:$_sequence:${file.key}:${kind.name}'),
            ),
            file: file,
            kind: kind,
            detectedAt: detectedAt,
          ),
        );
        changed = true;
      }

      for (final file in entry.value.values) {
        final old = previous[file.key];
        if (old == null) {
          record(file, ContentUpdateKind.added);
        } else if (old.revision != file.revision) {
          record(file, ContentUpdateKind.changed);
        }
      }
      for (final file in previous.values) {
        if (!entry.value.containsKey(file.key)) {
          record(file, ContentUpdateKind.removed);
        }
      }
      // Update file IDs even when a rebuilt index assigned new ones.
      _baselines[entry.key] = entry.value;
    }
    return changed;
  }

  void setDisposition(String id, ContentUpdateDisposition disposition) {
    final index = _events.indexWhere((event) => event.id == id);
    if (index >= 0) {
      _events[index] = _events[index].withDisposition(disposition);
    }
  }

  Map<String, Object?> toJson() => {
    'format_version': 1,
    'sequence': _sequence,
    'subscriptions': {
      for (final entry in _baselines.entries)
        entry.key: [for (final file in entry.value.values) file.toJson()],
    },
    'events': [for (final event in _events) event.toJson()],
  };

  static ContentUpdates fromJson(Object? raw) {
    if (raw is! Map ||
        raw['format_version'] != 1 ||
        raw['sequence'] is! int ||
        (raw['sequence'] as int) < 0 ||
        raw['subscriptions'] is! Map ||
        raw['events'] is! List) {
      throw const FormatException('Nicht unterstützter Update-Posteingang.');
    }
    final state = ContentUpdates().._sequence = raw['sequence'] as int;
    for (final entry in (raw['subscriptions'] as Map).entries) {
      if (entry.key is! String || entry.value is! List) {
        throw const FormatException('Ungültiges Inhaltsabo.');
      }
      final files = (entry.value as List).map(ContentUpdateFile.fromJson);
      if (files.any((file) => file.workId != entry.key)) {
        throw const FormatException('Inhaltsabo gehört zu einem anderen Werk.');
      }
      state.subscribe(entry.key as String, files);
    }
    state._events.addAll(
      (raw['events'] as List).map(ContentUpdateEvent.fromJson),
    );
    if (state._events.length > state._sequence ||
        state._events.map((e) => e.id).toSet().length != state._events.length) {
      throw const FormatException('Ungültige Update-Kennungen.');
    }
    return state;
  }
}
