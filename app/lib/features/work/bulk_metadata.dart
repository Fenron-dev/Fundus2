import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_settings.dart';
import '../../data/work_view.dart';
import '../../metadata/metadata_apply.dart';
import '../../metadata/metadata_providers.dart';
import 'metadata_dialog.dart';

/// Matching a whole shelf at once.
///
/// The single work dialog is the right tool for one work and the wrong one
/// for forty: a shelf of series with no pictures is one job, not forty. This
/// runs the same search over what the library is currently showing and applies
/// only what it is sure about — anything it is not sure about is listed and
/// left to be picked by hand, because a confidently wrong cover is worse than
/// a missing one.
Future<void> showBulkMetadata(
  BuildContext context, {
  required List<WorkView> works,
  required FundusLibrary library,
  required AppSettings settings,
  required VoidCallback onChanged,
  String? mediaTypeId,
}) => showDialog<void>(
  context: context,
  builder: (context) => _BulkMetadata(
    works: works,
    library: library,
    settings: settings,
    onChanged: onChanged,
    mediaTypeId: mediaTypeId,
  ),
);

enum _Outcome { applied, unsure, nothing, failed }

final class _Row {
  _Row(this.work, this.outcome, {this.note, this.best});

  final WorkView work;
  final _Outcome outcome;
  final String? note;
  final MetadataMatch? best;
}

class _BulkMetadata extends StatefulWidget {
  const _BulkMetadata({
    required this.works,
    required this.library,
    required this.settings,
    required this.onChanged,
    required this.mediaTypeId,
  });

  final List<WorkView> works;
  final FundusLibrary library;
  final AppSettings settings;
  final VoidCallback onChanged;
  final String? mediaTypeId;

  @override
  State<_BulkMetadata> createState() => _BulkMetadataState();
}

class _BulkMetadataState extends State<_BulkMetadata> {
  late MetadataProviderKind _provider = MetadataProviderKind.forMediaType(
    widget.mediaTypeId,
  ).first;
  bool _onlyWithoutCover = true;
  bool _running = false;
  bool _cancelled = false;
  int _done = 0;
  final _rows = <_Row>[];

  /// Only local works: a mirrored one belongs to the machine that holds it.
  List<WorkView> get _targets => [
    for (final work in widget.works)
      if (work.summary.sourceId == 'local')
        if (!_onlyWithoutCover || work.summary.coverPath == null) work,
  ];

  Future<void> _run() async {
    final targets = _targets;
    if (targets.isEmpty) return;
    setState(() {
      _running = true;
      _cancelled = false;
      _done = 0;
      _rows.clear();
    });
    final search = MetadataSearch([
      providerFor(_provider, apiKey: widget.settings.tmdbKey),
    ]);
    for (final work in targets) {
      if (_cancelled || !mounted) break;
      try {
        final matches = await search.search(
          work.title,
          language: widget.settings.metadataLanguage,
          year: work.summary.publishedYear,
        );
        final best = matches.firstOrNull;
        if (best == null) {
          _rows.add(_Row(work, _Outcome.nothing));
        } else if (best.needsConfirmation) {
          _rows.add(
            _Row(
              work,
              _Outcome.unsure,
              note: '„${best.candidate.title}"?',
              best: best,
            ),
          );
        } else {
          final result = await applyMetadata(
            library: widget.library,
            work: work,
            candidate: best.candidate,
          );
          _rows.add(
            _Row(
              work,
              _Outcome.applied,
              note: result.coverFetched
                  ? '${result.title} · mit Bild'
                  : result.title,
            ),
          );
        }
      } on Object catch (error) {
        _rows.add(
          _Row(
            work,
            _Outcome.failed,
            note: error is MetadataProviderException ? error.message : null,
          ),
        );
      }
      if (!mounted) return;
      setState(() => _done++);
      widget.onChanged();
      // The public services are free and rate-limited; a pause between works
      // is what keeps a shelf of forty from being refused halfway through.
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    if (mounted) setState(() => _running = false);
  }

  Future<void> _pick(_Row row) async {
    final candidate = await showMetadataDialog(
      context,
      work: row.work,
      settings: widget.settings,
    );
    if (candidate == null || !mounted) return;
    await applyMetadata(
      library: widget.library,
      work: row.work,
      candidate: candidate,
    );
    widget.onChanged();
    if (!mounted) return;
    setState(() {
      final index = _rows.indexOf(row);
      if (index >= 0) {
        _rows[index] = _Row(row.work, _Outcome.applied, note: candidate.title);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final targets = _targets.length;

    return AlertDialog(
      title: const Text('Details für mehrere Werke'),
      content: SizedBox(
        width: 680,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Sucht zu jedem Werk in dieser Ansicht und übernimmt nur, was '
              'eindeutig ist. Alles andere wird aufgelistet und bleibt so, '
              'wie es ist — ein falsches Titelbild ist schlimmer als keins.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.textMuted,
              ),
            ),
            const SizedBox(height: FundusSpace.x3),
            Wrap(
              spacing: FundusSpace.x2,
              runSpacing: FundusSpace.x2,
              children: [
                for (final kind in MetadataProviderKind.values)
                  ChoiceChip(
                    selected: _provider == kind,
                    onSelected: _running
                        ? null
                        : (_) => setState(() => _provider = kind),
                    label: Text(kind.label),
                  ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _onlyWithoutCover,
              onChanged: _running
                  ? null
                  : (value) => setState(() => _onlyWithoutCover = value),
              title: const Text('Nur Werke ohne Titelbild'),
            ),
            Text(
              _running
                  ? '$_done von $targets'
                  : '$targets Werke werden abgeglichen',
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.textFaint,
              ),
            ),
            if (_running) ...[
              const SizedBox(height: FundusSpace.x2),
              LinearProgressIndicator(
                value: targets == 0 ? null : _done / targets,
              ),
            ],
            if (_rows.isNotEmpty) ...[
              const SizedBox(height: FundusSpace.x3),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _rows.length,
                  itemBuilder: (context, index) {
                    final row = _rows[_rows.length - 1 - index];
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        switch (row.outcome) {
                          _Outcome.applied => FundusIcons.check,
                          _Outcome.unsure => FundusIcons.search,
                          _ => FundusIcons.warning,
                        },
                        size: FundusIcons.sizeSm,
                        color: row.outcome == _Outcome.applied
                            ? tokens.textMuted
                            : tokens.textFaint,
                      ),
                      title: Text(row.work.title),
                      subtitle: Text(
                        row.note ??
                            switch (row.outcome) {
                              _Outcome.nothing => 'Nichts gefunden',
                              _Outcome.failed => 'Fehlgeschlagen',
                              _ => '',
                            },
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: row.outcome == _Outcome.unsure
                          ? TextButton(
                              onPressed: () => unawaited(_pick(row)),
                              child: const Text('Auswählen'),
                            )
                          : null,
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _running
              ? () => setState(() => _cancelled = true)
              : () => Navigator.of(context).pop(),
          child: Text(_running ? 'Anhalten' : 'Schließen'),
        ),
        FilledButton(
          onPressed: _running || targets == 0 ? null : () => unawaited(_run()),
          child: const Text('Abgleichen'),
        ),
      ],
    );
  }
}
