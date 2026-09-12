import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../data/work_view.dart';
import '../../data/media_type.dart';

/// Editing a work by hand.
///
/// What is typed here is written as a *user* value, which the metadata layer
/// ranks above anything a scan or a provider produces. So a title corrected
/// here survives the next scan and the next match — the point of correcting
/// it is that it stays corrected.
Future<bool> showMetadataEditor(
  BuildContext context, {
  required FundusLibrary library,
  required WorkView work,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => _MetadataEditor(library: library, work: work),
    ) ??
    false;

class _MetadataEditor extends StatefulWidget {
  const _MetadataEditor({required this.library, required this.work});

  final FundusLibrary library;
  final WorkView work;

  @override
  State<_MetadataEditor> createState() => _MetadataEditorState();
}

class _MetadataEditorState extends State<_MetadataEditor> {
  late final _fields = <String, TextEditingController>{
    'title': TextEditingController(text: widget.work.summary.title),
    'authors': TextEditingController(
      text: widget.work.summary.authors.isEmpty
          ? widget.work.summary.author
          : widget.work.summary.authors.join(', '),
    ),
    'subtitle': TextEditingController(text: widget.work.summary.subtitle ?? ''),
    'series': TextEditingController(text: widget.work.summary.series ?? ''),
    'sequence': TextEditingController(
      text: widget.work.summary.seriesSequence?.toString() ?? '',
    ),
    'year': TextEditingController(
      text: widget.work.summary.publishedYear?.toString() ?? '',
    ),
    'publisher': TextEditingController(
      text: widget.work.summary.publisher ?? '',
    ),
    'language': TextEditingController(text: widget.work.summary.language ?? ''),
    'genres': TextEditingController(
      text: widget.work.summary.genres.join(', '),
    ),
    'description': TextEditingController(
      text: widget.work.summary.description ?? '',
    ),
  };

  /// Die anderen Bände derselben Reihe, nach dem Namen gesucht, den die
  /// Reihe beim Öffnen hatte — so lässt sich eine Reihe hier umbenennen und
  /// alle Bände ziehen mit.
  late final List<LibraryWorkSummary> _siblings = widget.library.isReadOnly
      ? const []
      : seriesSiblings(
          widget.library.listWorks(),
          workId: widget.work.id,
          series: widget.work.summary.series,
        );
  bool _wholeSeries = false;
  late String _kind = widget.work.summary.kind;
  late bool _hhh = widget.work.summary.isHhh;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  String _text(String key) => _fields[key]!.text.trim();

  List<String> _list(String key) => _text(key)
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);

  Future<void> _save() async {
    final authors = _list('authors');
    if (_text('title').isEmpty || authors.isEmpty) {
      setState(
        () =>
            _error = 'Titel und mindestens ein Urheber müssen ausgefüllt sein.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.library.updateWorkMetadata(
        workId: widget.work.id,
        title: _text('title'),
        authors: authors,
        subtitle: _text('subtitle').isEmpty ? null : _text('subtitle'),
        series: _text('series').isEmpty ? null : _text('series'),
        seriesSequence: double.tryParse(_text('sequence').replaceAll(',', '.')),
        language: _text('language').isEmpty ? null : _text('language'),
        description: _text('description').isEmpty ? null : _text('description'),
        publisher: _text('publisher').isEmpty ? null : _text('publisher'),
        publishedYear: int.tryParse(_text('year')),
        genres: _list('genres'),
      );
      widget.library.updateWorkKind(
        workId: widget.work.id,
        kind: _kind,
        contentSensitivity: _hhh ? 'adult_explicit' : 'general',
      );
      // „Für alle Bände" schreibt nur, was eine Reihe gemeinsam hat. Ein
      // Band, der dabei nicht angenommen wird, hält den Rest nicht auf.
      if (_wholeSeries) {
        for (final sibling in _siblings) {
          try {
            await applySharedFields(
              library: widget.library,
              work: sibling,
              authors: authors,
              series: _text('series').isEmpty ? null : _text('series'),
              publisher: _text('publisher').isEmpty ? null : _text('publisher'),
              language: _text('language').isEmpty ? null : _text('language'),
              genres: _list('genres'),
            );
          } on Object {
            continue;
          }
        }
      }
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error is ArgumentError
            ? '${error.message}'
            : 'Speichern fehlgeschlagen.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Werk bearbeiten'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: FundusSpace.x3),
                child: Text(
                  'Was hier steht, gilt als von Hand gesetzt: kein Scan und '
                  'kein Abgleich überschreibt es später wieder.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: context.fundus.textFaint,
                  ),
                ),
              ),
              _Field(label: 'Titel', controller: _fields['title']!),
              _Field(
                label: 'Urheber',
                controller: _fields['authors']!,
                helper: 'Mehrere durch Komma getrennt.',
              ),
              _Field(label: 'Untertitel', controller: _fields['subtitle']!),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: _Field(
                      label: 'Reihe',
                      controller: _fields['series']!,
                    ),
                  ),
                  const SizedBox(width: FundusSpace.x3),
                  Expanded(
                    child: _Field(
                      label: 'Band',
                      controller: _fields['sequence']!,
                    ),
                  ),
                ],
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _Field(label: 'Jahr', controller: _fields['year']!),
                  ),
                  const SizedBox(width: FundusSpace.x3),
                  Expanded(
                    flex: 2,
                    child: _Field(
                      label: 'Verlag',
                      controller: _fields['publisher']!,
                    ),
                  ),
                  const SizedBox(width: FundusSpace.x3),
                  Expanded(
                    child: _Field(
                      label: 'Sprache',
                      controller: _fields['language']!,
                    ),
                  ),
                ],
              ),
              _Field(
                label: 'Genres',
                controller: _fields['genres']!,
                helper: 'Mehrere durch Komma getrennt.',
              ),
              _Field(
                label: 'Beschreibung',
                controller: _fields['description']!,
                lines: 5,
              ),
              DropdownButtonFormField<String>(
                initialValue: _kind,
                decoration: const InputDecoration(
                  labelText: 'Interner Medientyp',
                  border: OutlineInputBorder(),
                  helperText:
                      'Steuert Player, Reader und die Bibliotheksgruppe.',
                ),
                items: [
                  for (final type in MediaTypes.all)
                    for (final kind in type.workKinds)
                      DropdownMenuItem(value: kind, child: Text(type.label)),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _kind = value!),
              ),
              const SizedBox(height: FundusSpace.x2),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Als HHH kennzeichnen'),
                subtitle: const Text(
                  'Das Werk wird in Schutzmodus und auf eingeschränkten Geräten ausgeblendet.',
                ),
                value: _hhh,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _hhh = value),
              ),
              if (_siblings.isNotEmpty)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _wholeSeries,
                  onChanged: _saving
                      ? null
                      : (on) => setState(() => _wholeSeries = on ?? false),
                  title: Text(
                    'Für alle ${_siblings.length + 1} Bände der Reihe',
                  ),
                  subtitle: Text(
                    'Urheber, Reihe, Verlag, Sprache und Genres — Titel, '
                    'Band und Beschreibung bleiben je Band.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: context.fundus.textFaint,
                    ),
                  ),
                ),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: FundusSpace.x2),
                  child: Text(
                    error,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Speichern'),
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.helper,
    this.lines = 1,
  });

  final String label;
  final TextEditingController controller;
  final String? helper;
  final int lines;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FundusSpace.x3),
    child: TextField(
      controller: controller,
      minLines: lines,
      maxLines: lines,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}

/// The other volumes of the same series.
///
/// „Alle Bände" means the works that share a series name — matched without
/// case and without the spaces around it, because one volume was typed by
/// hand and the next came from a folder name. The work being edited is never
/// among them; it is saved on its own path.
List<LibraryWorkSummary> seriesSiblings(
  List<LibraryWorkSummary> works, {
  required String workId,
  required String? series,
}) {
  final name = series?.trim().toLowerCase();
  if (name == null || name.isEmpty) return const [];
  return [
    for (final work in works)
      if (work.id != workId && work.series?.trim().toLowerCase() == name) work,
  ];
}

/// Writes the fields a whole series shares onto one of its volumes.
///
/// Title, band and blurb belong to the single volume and are left alone —
/// what a series has in common is who wrote it, what it is called, who
/// published it, in which language and under which genres. Everything else on
/// the sibling keeps the value it already had, because a blank field here is
/// not a statement that the field is empty.
Future<void> applySharedFields({
  required FundusLibrary library,
  required LibraryWorkSummary work,
  required List<String> authors,
  required String? series,
  required String? publisher,
  required String? language,
  required List<String> genres,
}) => library.updateWorkMetadata(
  workId: work.id,
  title: work.title,
  authors: authors.isEmpty
      ? (work.authors.isEmpty ? [work.author] : work.authors)
      : authors,
  subtitle: work.subtitle,
  series: series ?? work.series,
  seriesSequence: work.seriesSequence,
  narrators: work.narrators,
  language: language ?? work.language,
  description: work.description,
  publisher: publisher ?? work.publisher,
  publishedYear: work.publishedYear,
  genres: genres.isEmpty ? null : genres,
);
