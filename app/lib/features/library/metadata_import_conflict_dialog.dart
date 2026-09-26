import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';

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
