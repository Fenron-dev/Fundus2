import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';

Future<void> showMetadataHistory(
  BuildContext context, {
  required FundusScopeState scope,
  required String workId,
}) => showDialog<void>(
  context: context,
  builder: (_) => _MetadataHistoryDialog(scope: scope, workId: workId),
);

class _MetadataHistoryDialog extends StatefulWidget {
  const _MetadataHistoryDialog({required this.scope, required this.workId});
  final FundusScopeState scope;
  final String workId;
  @override
  State<_MetadataHistoryDialog> createState() => _MetadataHistoryDialogState();
}

class _MetadataHistoryDialogState extends State<_MetadataHistoryDialog> {
  late final _vault = widget.scope.library.library;
  late final _changes = Listenable.merge([
    widget.scope.library,
    widget.scope.protection,
    widget.scope.settings,
  ]);
  String? _batchId, _error;
  bool _wholeBatch = false, _busy = false;
  final _selected = <String>{};
  final _expanded = <String>{};

  Set<String> get _visibleWorks => {
    for (final work in widget.scope.library.works)
      if (_wholeBatch || work.id == widget.workId) work.id,
  };
  Set<String> get _visibleProperties => {
    for (final definition in _vault!.listPropertyDefinitions(
      includeProtected: widget.scope.protection.isUnlocked,
    ))
      if (definition.valueType != PropertyValueType.rating) definition.id,
  };
  Set<String>? get _visibleTags =>
      widget.scope.protection.isUnlocked ? null : _vault!.listTags().toSet();

  Future<void> _undo(MetadataChangeBatch batch) async {
    if (_vault == null || !identical(_vault, widget.scope.library.library)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _vault.undoMetadataBatch(
        batch.id,
        visibleWorkIds: _visibleWorks,
        selectedKeys: {..._selected},
        expectedAfter: {
          for (final change in batch.changes)
            if (_selected.contains(change.key)) change.key: change.after,
        },
        visiblePropertyIds: _visibleProperties,
        visibleTagNames: _visibleTags,
        includeProtected: widget.scope.protection.isUnlocked,
      );
      for (final id
          in result.applicable.map((change) => change.workId).toSet()) {
        widget.scope.library.refreshWork(id);
      }
      if (!mounted) return;
      setState(() {
        _selected.clear();
        _batchId = null;
        _error =
            '${result.applicable.length} Felder zurückgenommen. Der Verlauf bleibt erhalten.';
      });
    } on MetadataUndoConflictException catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } on Object {
      if (mounted) {
        setState(
          () => _error =
              'Nicht zurückgenommen. Bitte Verlauf, Feldtypen und Vault-Zugriff prüfen.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _changes,
    builder: (context, _) {
      final available =
          _vault != null && identical(_vault, widget.scope.library.library);
      final history = available
          ? _vault.indexedMetadataHistory(
              visibleWorkIds: _visibleWorks,
              visiblePropertyIds: _visibleProperties,
              visibleTagNames: _visibleTags,
              includeProtected: widget.scope.protection.isUnlocked,
            )
          : MetadataHistory();
      final batches = history.batches.reversed.toList();
      final batch = batches.where((entry) => entry.id == _batchId).firstOrNull;
      final definitions = available
          ? {
              for (final field in _vault.listPropertyDefinitions(
                includeProtected: widget.scope.protection.isUnlocked,
              ))
                field.id: field.name,
            }
          : <String, String>{};
      final plan = batch == null
          ? null
          : _vault!.previewMetadataUndo(
              batch.id,
              visibleWorkIds: _visibleWorks,
              visiblePropertyIds: _visibleProperties,
              visibleTagNames: _visibleTags,
              includeProtected: widget.scope.protection.isUnlocked,
            );
      final compatible = {
        for (final change in plan?.applicable ?? <MetadataFieldChange>[])
          if (change.field != 'cover' && change.field != 'backdrop') change.key,
      };
      final activeSelection =
          batch?.changes
              .where((change) => _selected.contains(change.key))
              .toList() ??
          [];
      return AlertDialog(
        title: const Text('Metadatenverlauf'),
        content: SizedBox(
          width: MediaQuery.sizeOf(context).width * .8,
          height: MediaQuery.sizeOf(context).height * .5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Vorher → nachher. Fortschritt, persönliche Bewertungen, Notizen und Lesezeichen werden nicht zurückgenommen.',
              ),
              if (available && _vault.metadataHistoryError != null)
                const Text(
                  'Der Verlauf liegt im Index; seine portable Kopie konnte noch nicht gesichert werden. Bitte Vault-Zugriff prüfen und ein Backup erstellen.',
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: FundusSpace.x2),
                  child: Text(_error!),
                ),
              const SizedBox(height: FundusSpace.x2),
              Expanded(
                child: !available
                    ? const Center(
                        child: Text('Die Bibliothek wurde gewechselt.'),
                      )
                    : batch == null
                    ? batches.isEmpty
                          ? const Center(
                              child: Text(
                                'Keine sichtbaren Metadatenänderungen für dieses Werk. Frühere Änderungen vor Einführung des Verlaufs sind nicht enthalten.',
                              ),
                            )
                          : ListView.builder(
                              itemCount: batches.length,
                              itemBuilder: (context, index) {
                                final item = batches[index];
                                final at = item.at.toLocal();
                                return ListTile(
                                  title: Text(
                                    '${at.day}.${at.month}.${at.year} · ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')} · ${item.source}',
                                  ),
                                  subtitle: Text(
                                    '${item.changes.length} sichtbare Felder${item.reversesBatchId == null ? '' : ' · Rücknahme'}',
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => setState(() {
                                    _batchId = item.id;
                                    _selected.clear();
                                    _error = null;
                                  }),
                                );
                              },
                            )
                    : ListView.builder(
                        itemCount: batch.changes.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                'Andere sichtbare Werke dieses Änderungspakets einbeziehen',
                              ),
                              subtitle: const Text(
                                'Ausgeblendete Werke und geschützte Felder werden nie einbezogen.',
                              ),
                              value: _wholeBatch,
                              onChanged: _busy
                                  ? null
                                  : (value) => setState(() {
                                      _wholeBatch = value ?? false;
                                      _selected.clear();
                                    }),
                            );
                          }
                          final change = batch.changes[index - 1];
                          final allowed =
                              compatible.contains(change.key) &&
                              !_vault.isReadOnly;
                          final work = widget.scope.library.workById(
                            change.workId,
                          );
                          final label = change.field.startsWith('property:')
                              ? definitions[change.field.substring(9)] ??
                                    'Eigenschaft'
                              : _labels[change.field] ?? change.field;
                          return CheckboxListTile(
                            value: _selected.contains(change.key),
                            onChanged: !allowed || _busy
                                ? null
                                : (value) => setState(() {
                                    if (value == true) {
                                      _selected.add(change.key);
                                    } else {
                                      _selected.remove(change.key);
                                    }
                                  }),
                            title: Text(
                              '${_wholeBatch ? '${work?.title ?? ''} · ' : ''}$label',
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${_display(change.before)} → ${_display(change.after)}',
                                  maxLines: _expanded.contains(change.key)
                                      ? null
                                      : 3,
                                  overflow: _expanded.contains(change.key)
                                      ? null
                                      : TextOverflow.ellipsis,
                                ),
                                Text(
                                  'Herkunft: ${change.before.source ?? 'ohne Angabe'} → ${change.after.source ?? 'ohne Angabe'}${change.before.locked ? ' · vorher manuell gesperrt' : ''}',
                                ),
                                if (!allowed)
                                  Text(
                                    _vault.isReadOnly
                                        ? 'Nur lesen'
                                        : change.field == 'cover' ||
                                              change.field == 'backdrop'
                                        ? 'Bildversionen sind noch nicht rücknehmbar.'
                                        : 'Seitdem geändert – wird nicht zurückgenommen.',
                                  ),
                                TextButton(
                                  onPressed: () => setState(() {
                                    if (!_expanded.add(change.key)) {
                                      _expanded.remove(change.key);
                                    }
                                  }),
                                  child: Text(
                                    _expanded.contains(change.key)
                                        ? 'Vergleich verkleinern'
                                        : 'Vergleich vergrößern',
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
          if (batch != null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _batchId = null;
                      _selected.clear();
                      _wholeBatch = false;
                    }),
              child: const Text('Zur Liste'),
            ),
          if (batch != null && !_vault!.isReadOnly)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _selected.clear();
                      _selected.addAll(compatible);
                    }),
              child: const Text('Unveränderte Felder auswählen'),
            ),
          if (batch != null && !_vault!.isReadOnly)
            FilledButton(
              onPressed: _busy || activeSelection.isEmpty
                  ? null
                  : () => _undo(batch),
              child: Text('${activeSelection.length} Felder zurücknehmen'),
            ),
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Schließen'),
          ),
        ],
      );
    },
  );
}

String _display(MetadataFieldState state) {
  if (!state.present) return 'nicht vorhanden';
  final value = state.value;
  if (value == null) return 'leer';
  if (value is String) return value.isEmpty ? 'leer' : value;
  if (value is List) return value.isEmpty ? 'leer' : value.join(', ');
  return jsonEncode(value);
}

const _labels = {
  'title': 'Titel',
  'author': 'Urheber',
  'authors': 'Urheber',
  'subtitle': 'Untertitel',
  'alternate_titles': 'Alternative Titel',
  'series': 'Reihe',
  'series_sequence': 'Band',
  'narrators': 'Sprecher',
  'language': 'Sprache',
  'description': 'Beschreibung',
  'publisher': 'Verlag',
  'published_year': 'Jahr',
  'genres': 'Genres',
  'tags': 'Tags',
  'publication_status': 'Veröffentlichung',
  'personal_status': 'Mein Status',
  'kind': 'Medientyp',
  'content_sensitivity': 'Inhaltsschutz',
  'content_style': 'Stil',
  'external_ids': 'Externe Quellen',
  'cover': 'Titelbild',
  'backdrop': 'Hintergrundbild',
};
