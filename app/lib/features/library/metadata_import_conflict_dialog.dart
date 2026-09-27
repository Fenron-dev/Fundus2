import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';

/// Opens all pending metadata changes in one inbox instead of showing one
/// modal per work. A null result means “later”; an empty map means “keep all
/// current values”. The map contains the fields to import per list index.
Future<Map<int, Set<String>>?> showMetadataImportConflictInboxDialog(
  BuildContext context,
  List<MetadataImportConflict> conflicts,
) => showDialog<Map<int, Set<String>>>(
  context: context,
  barrierDismissible: false,
  builder: (context) => _MetadataImportConflictInbox(conflicts: conflicts),
);

Future<Set<String>?> showMetadataImportConflictDialog(
  BuildContext context,
  MetadataImportConflict conflict,
) => showDialog<Set<String>>(
  context: context,
  barrierDismissible: false,
  builder: (context) => _MetadataImportConflictDialog(conflict: conflict),
);

class _MetadataImportConflictDialog extends StatefulWidget {
  const _MetadataImportConflictDialog({required this.conflict});

  final MetadataImportConflict conflict;

  @override
  State<_MetadataImportConflictDialog> createState() =>
      _MetadataImportConflictDialogState();
}

class _MetadataImportConflictDialogState
    extends State<_MetadataImportConflictDialog> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final conflict = widget.conflict;
    final source = switch (conflict.source) {
      WorkMetadataSource.fero => 'Fero',
      WorkMetadataSource.abs => 'Audiobookshelf',
      _ => conflict.source.name,
    };
    return AlertDialog(
      title: const Text('Metadaten-Konflikt'),
      content: SizedBox(
        width: 680,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '„${conflict.workTitle}“ enthält in $source andere Angaben. '
              'Markiere, welche Werte Fundus übernehmen soll.',
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final field in conflict.fields)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _selected.contains(field.field),
                      onChanged: (value) => setState(() {
                        if (value ?? false) {
                          _selected.add(field.field);
                        } else {
                          _selected.remove(field.field);
                        }
                      }),
                      title: Text(_fieldLabel(field.field)),
                      subtitle: Text(
                        'Fundus: ${_display(field.currentValue)}\n'
                        '$source: ${_display(field.incomingValue)}',
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(<String>{}),
          child: const Text('Fundus behalten'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(Set.of(_selected)),
          child: const Text('Auswahl übernehmen'),
        ),
      ],
    );
  }

  static String _display(Object? value) {
    if (value is Iterable) return value.join(', ');
    final text = '$value'.trim();
    return text.length <= 240 ? text : '${text.substring(0, 237)}…';
  }

  static String _fieldLabel(String field) => switch (field) {
    'title' => 'Titel',
    'author' || 'authors' => 'Urheber',
    'subtitle' => 'Untertitel',
    'alternate_titles' => 'Alternative Titel',
    'series' => 'Reihe',
    'series_sequence' => 'Band/Reihenfolge',
    'narrators' => 'Sprecher',
    'language' => 'Sprache',
    'description' => 'Beschreibung',
    'publisher' => 'Verlag',
    'published_year' => 'Erscheinungsjahr',
    'genres' => 'Genres',
    'publication_status' => 'Veröffentlichungsstatus',
    _ => field,
  };
}

class _MetadataImportConflictInbox extends StatefulWidget {
  const _MetadataImportConflictInbox({required this.conflicts});

  final List<MetadataImportConflict> conflicts;

  @override
  State<_MetadataImportConflictInbox> createState() =>
      _MetadataImportConflictInboxState();
}

class _MetadataImportConflictInboxState
    extends State<_MetadataImportConflictInbox> {
  final Map<int, Set<String>> _selected = {};

  Set<String> _fieldsFor(int index) =>
      _selected.putIfAbsent(index, () => <String>{});

  @override
  Widget build(BuildContext context) {
    final sourceCount = <WorkMetadataSource, int>{};
    for (final conflict in widget.conflicts) {
      sourceCount[conflict.source] = (sourceCount[conflict.source] ?? 0) + 1;
    }
    return AlertDialog(
      title: Text('${widget.conflicts.length} Metadatenänderungen'),
      content: SizedBox(
        width: 760,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Die Änderungen wurden gesammelt. Du kannst einzelne Felder '
              'übernehmen oder alles später in Einstellungen > '
              'Benachrichtigungen bearbeiten.',
            ),
            const SizedBox(height: 8),
            Text(
              sourceCount.entries
                  .map((entry) => '${_sourceLabel(entry.key)}: ${entry.value}')
                  .join(' · '),
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: widget.conflicts.length,
                itemBuilder: (context, index) {
                  final conflict = widget.conflicts[index];
                  final selected = _fieldsFor(index);
                  return Card(
                    child: ExpansionTile(
                      initiallyExpanded: widget.conflicts.length <= 3,
                      title: Text(conflict.workTitle),
                      subtitle: Text(
                        '${_sourceLabel(conflict.source)} · '
                        '${conflict.fields.length} Felder',
                      ),
                      children: [
                        for (final field in conflict.fields)
                          CheckboxListTile(
                            dense: true,
                            value: selected.contains(field.field),
                            onChanged: (value) => setState(() {
                              if (value ?? false) {
                                selected.add(field.field);
                              } else {
                                selected.remove(field.field);
                              }
                            }),
                            title: Text(_fieldLabel(field.field)),
                            subtitle: Text(
                              'Fundus: ${_display(field.currentValue)}\n'
                              '${_sourceLabel(conflict.source)}: '
                              '${_display(field.incomingValue)}',
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Später'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(<int, Set<String>>{}),
          child: const Text('Alle bisherigen behalten'),
        ),
        OutlinedButton(
          onPressed: () {
            final result = <int, Set<String>>{
              for (var index = 0; index < widget.conflicts.length; index++)
                index: {
                  for (final field in widget.conflicts[index].fields)
                    field.field,
                },
            };
            Navigator.of(context).pop(result);
          },
          child: const Text('Alle neuen übernehmen'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop({
            for (final entry in _selected.entries)
              if (entry.value.isNotEmpty) entry.key: Set.of(entry.value),
          }),
          child: const Text('Auswahl übernehmen'),
        ),
      ],
    );
  }
}

String _sourceLabel(WorkMetadataSource source) => switch (source) {
  WorkMetadataSource.fero => 'Fero',
  WorkMetadataSource.abs => 'Audiobookshelf',
  _ => source.name,
};

String _display(Object? value) {
  if (value is Iterable) return value.join(', ');
  final text = '$value'.trim();
  return text.length <= 240 ? text : '${text.substring(0, 237)}…';
}

String _fieldLabel(String field) => switch (field) {
  'title' => 'Titel',
  'author' || 'authors' => 'Urheber',
  'subtitle' => 'Untertitel',
  'alternate_titles' => 'Alternative Titel',
  'series' => 'Reihe',
  'series_sequence' => 'Band/Reihenfolge',
  'narrators' => 'Sprecher',
  'language' => 'Sprache',
  'description' => 'Beschreibung',
  'publisher' => 'Verlag',
  'published_year' => 'Erscheinungsjahr',
  'genres' => 'Genres',
  'publication_status' => 'Veröffentlichungsstatus',
  _ => field,
};
