import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../data/work_view.dart';
import 'metadata_editor.dart';

/// Mehrere Werke auf einmal pflegen.
///
/// Zwölf Bände einer Reihe haben denselben Urheber, denselben Verlag und
/// dieselbe Reihe; sie einzeln einzutragen ist Arbeit ohne Erkenntnis.
/// Geschrieben wird nur, was hier ausgefüllt ist — ein leeres Feld ist keine
/// Aussage, sondern die Abwesenheit einer. Titel, Band und Beschreibung
/// stehen deshalb gar nicht zur Wahl: die gehören dem einzelnen Werk.
Future<bool> showBatchEditor(
  BuildContext context, {
  required FundusLibrary library,
  required List<WorkView> works,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => _BatchEditor(library: library, works: works),
    ) ??
    false;

class _BatchEditor extends StatefulWidget {
  const _BatchEditor({required this.library, required this.works});

  final FundusLibrary library;
  final List<WorkView> works;

  @override
  State<_BatchEditor> createState() => _BatchEditorState();
}

class _BatchEditorState extends State<_BatchEditor> {
  late final _fields = <String, TextEditingController>{
    'authors': TextEditingController(text: _shared((work) => work.author)),
    'series': TextEditingController(text: _shared((work) => work.series)),
    'publisher': TextEditingController(text: _shared((work) => work.publisher)),
    'language': TextEditingController(text: _shared((work) => work.language)),
    'genres': TextEditingController(
      text: _shared((work) => work.genres.join(', ')),
    ),
  };
  bool _saving = false;
  String? _error;

  /// Was alle ausgewählten Werke gemeinsam haben, sonst leer.
  ///
  /// Ein Feld, in dem schon der gemeinsame Wert steht, sagt beim Öffnen die
  /// Wahrheit; eines, in dem verschiedene Werte stünden, bleibt leer und
  /// ändert dann auch nichts.
  String _shared(String? Function(LibraryWorkSummary work) read) {
    final values = {
      for (final work in widget.works) (read(work.summary) ?? '').trim(),
    };
    return values.length == 1 ? values.single : '';
  }

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
    setState(() {
      _saving = true;
      _error = null;
    });
    final authors = _list('authors');
    try {
      for (final work in widget.works) {
        await applySharedFields(
          library: widget.library,
          work: work.summary,
          authors: authors,
          series: _text('series').isEmpty ? null : _text('series'),
          publisher: _text('publisher').isEmpty ? null : _text('publisher'),
          language: _text('language').isEmpty ? null : _text('language'),
          genres: _list('genres'),
        );
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
    final tokens = context.fundus;

    return AlertDialog(
      title: Text('${widget.works.length} Werke bearbeiten'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Geschrieben wird nur, was hier steht. Was leer bleibt, '
                'bleibt an jedem Werk, wie es war — Titel, Band und '
                'Beschreibung gehören ohnehin dem einzelnen Werk.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tokens.textFaint,
                ),
              ),
              const SizedBox(height: FundusSpace.x4),
              _Field(
                label: 'Urheber',
                controller: _fields['authors']!,
                helper: 'Mehrere durch Komma getrennt.',
              ),
              _Field(label: 'Reihe', controller: _fields['series']!),
              _Field(label: 'Verlag', controller: _fields['publisher']!),
              _Field(label: 'Sprache', controller: _fields['language']!),
              _Field(
                label: 'Genres',
                controller: _fields['genres']!,
                helper: 'Mehrere durch Komma getrennt.',
              ),
              if (_error case final error?)
                Text(
                  error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
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
          child: Text('Auf ${widget.works.length} Werke schreiben'),
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.controller, this.helper});

  final String label;
  final TextEditingController controller;
  final String? helper;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FundusSpace.x3),
    child: TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}
