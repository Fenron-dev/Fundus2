import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_settings.dart';
import '../../data/work_view.dart';
import '../../metadata/metadata_apply.dart';
import '../../metadata/metadata_providers.dart';

/// Searches a work's details and returns what was picked.
///
/// The query starts as the work's own title, because that is what somebody
/// would type. Nothing is applied from here — the dialog answers with a
/// candidate and the fields that may be written, and the caller writes it, so
/// the same dialog serves one work and a whole shelf.
Future<MetadataChoice?> showMetadataDialog(
  BuildContext context, {
  required WorkView work,
  required AppSettings settings,
}) => showDialog<MetadataChoice>(
  context: context,
  builder: (context) => _MetadataDialog(work: work, settings: settings),
);

class _MetadataDialog extends StatefulWidget {
  const _MetadataDialog({required this.work, required this.settings});

  final WorkView work;
  final AppSettings settings;

  @override
  State<_MetadataDialog> createState() => _MetadataDialogState();
}

class _MetadataDialogState extends State<_MetadataDialog> {
  late final TextEditingController _query = TextEditingController(
    text: widget.work.title,
  );
  late final TextEditingController _key = TextEditingController(
    text: widget.settings.tmdbKey,
  );
  late final List<MetadataProviderKind> _suggested =
      MetadataProviderKind.forMediaType(widget.work.mediaType?.id);
  late MetadataProviderKind _provider = _suggested.first;
  late String _language = widget.settings.metadataLanguage;
  bool _loading = false;
  bool _allProviders = false;
  String? _error;
  List<MetadataMatch> _matches = const [];

  /// The match somebody tapped. While it is set the dialog shows what would
  /// change instead of the result list — picking is one decision, writing is
  /// another.
  MetadataCandidate? _chosen;
  final Set<MetadataField> _fields = {};

  @override
  void dispose() {
    _query.dispose();
    _key.dispose();
    super.dispose();
  }

  /// Which sources are offered, in the order that makes sense for this shelf.
  ///
  /// A film is not in Open Library and a manga is not on Audible; showing all
  /// of them equally is how somebody ends up searching the wrong catalogue
  /// and concluding the match is broken. The rest stay one tap away, because
  /// a light novel really does live in two places at once.
  List<MetadataProviderKind> get _visibleProviders => _allProviders
      ? [
          ..._suggested,
          ...MetadataProviderKind.values.where(
            (kind) => !_suggested.contains(kind),
          ),
        ]
      : _suggested;

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    if (_provider.needsKey && _key.text.trim().isEmpty) {
      setState(() => _error = 'Für TMDB wird ein eigener Schlüssel benötigt.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    if (_provider.needsKey) await widget.settings.setTmdbKey(_key.text);
    await widget.settings.setMetadataLanguage(_language);
    try {
      final results = await MetadataSearch([
        providerFor(_provider, apiKey: _key.text.trim()),
      ]).search(query, language: _language);
      if (!mounted) return;
      setState(() {
        _matches = results;
        _loading = false;
        if (results.isEmpty) _error = 'Keine passenden Treffer.';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is MetadataProviderException
            ? error.message
            : 'Die Suche ist fehlgeschlagen.';
      });
    }
  }

  void _choose(MetadataCandidate candidate) => setState(() {
    _chosen = candidate;
    _fields
      ..clear()
      ..addAll(offeredFields(candidate));
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final chosen = _chosen;

    if (chosen != null) {
      return AlertDialog(
        title: const Text('Was übernehmen?'),
        content: SizedBox(
          width: 640,
          child: _FieldChoice(
            work: widget.work,
            candidate: chosen,
            chosen: _fields,
            onToggle: (field, on) => setState(() {
              if (on) {
                _fields.add(field);
              } else {
                _fields.remove(field);
              }
            }),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => setState(() => _chosen = null),
            child: const Text('Zurück'),
          ),
          TextButton(
            onPressed: () => Navigator.of(
              context,
            ).pop(MetadataChoice(candidate: chosen, fields: const {})),
            child: const Text('Nur verknüpfen'),
          ),
          FilledButton(
            onPressed: _fields.isEmpty
                ? null
                : () => Navigator.of(context).pop(
                    MetadataChoice(candidate: chosen, fields: {..._fields}),
                  ),
            child: const Text('Übernehmen'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('Details abgleichen'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: FundusSpace.x2,
              runSpacing: FundusSpace.x2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final kind in _visibleProviders)
                  ChoiceChip(
                    selected: _provider == kind,
                    onSelected: _loading
                        ? null
                        : (_) => setState(() => _provider = kind),
                    label: Text(kind.label),
                  ),
                if (!_allProviders &&
                    _suggested.length < MetadataProviderKind.values.length)
                  TextButton(
                    onPressed: () => setState(() => _allProviders = true),
                    child: const Text('Andere Quellen'),
                  ),
              ],
            ),
            const SizedBox(height: FundusSpace.x3),
            TextField(
              controller: _query,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => unawaited(_search()),
              decoration: const InputDecoration(
                labelText: 'Titel',
                border: OutlineInputBorder(),
              ),
            ),
            if (_provider.needsKey) ...[
              const SizedBox(height: FundusSpace.x2),
              TextField(
                controller: _key,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'TMDB-Schlüssel',
                  helperText: 'Bleibt auf diesem Gerät, nie in der Bibliothek.',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: FundusSpace.x2),
            Row(
              children: [
                Text(
                  'Sprache',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: tokens.textFaint,
                  ),
                ),
                const SizedBox(width: FundusSpace.x3),
                for (final entry in const [
                  ('de-DE', 'Deutsch'),
                  ('en-US', 'English'),
                  ('ja-JP', 'Original'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: FundusSpace.x2),
                    child: ChoiceChip(
                      selected: _language == entry.$1,
                      onSelected: _loading
                          ? null
                          : (_) => setState(() => _language = entry.$1),
                      label: Text(entry.$2),
                    ),
                  ),
              ],
            ),
            // Audible führt je Land einen eigenen Katalog — die Sprache
            // entscheidet also, welche Ausgabe eines Hörbuchs gefunden wird.
            if (_provider == MetadataProviderKind.audible)
              Padding(
                padding: const EdgeInsets.only(top: FundusSpace.x2),
                child: Text(
                  'Audible antwortet je Sprache aus einem eigenen Shop — '
                  'die deutsche Ausgabe hat andere Sprecher als die '
                  'englische.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.textFaint,
                  ),
                ),
              ),
            if (_loading) ...[
              const SizedBox(height: FundusSpace.x3),
              const LinearProgressIndicator(),
            ],
            if (_error case final error?) ...[
              const SizedBox(height: FundusSpace.x2),
              Text(
                error,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (_matches.isNotEmpty) ...[
              const SizedBox(height: FundusSpace.x3),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _matches.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: tokens.divider),
                  itemBuilder: (context, index) => _MatchRow(
                    match: _matches[index],
                    onTap: () => _choose(_matches[index].candidate),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: _loading ? null : () => unawaited(_search()),
          child: const Text('Suchen'),
        ),
      ],
    );
  }
}

/// The fields this match actually has something to say about.
///
/// A checkbox for a field the service left empty would promise something it
/// cannot deliver, so it is not offered at all.
Set<MetadataField> offeredFields(MetadataCandidate candidate) => {
  MetadataField.title,
  if (candidate.authors.isNotEmpty) MetadataField.authors,
  if (candidate.series != null) MetadataField.series,
  if (candidate.releaseYear != null) MetadataField.year,
  if (candidate.publisher != null) MetadataField.publisher,
  if (candidate.language != null) MetadataField.language,
  if (candidate.genres.isNotEmpty) MetadataField.genres,
  if (candidate.description != null) MetadataField.description,
  if (candidate.posterUrl != null) MetadataField.cover,
  if (candidate.backdropUrl != null) MetadataField.backdrop,
};

/// What a field holds now, in the same words the work's page uses.
String currentValue(WorkView work, MetadataField field) {
  final summary = work.summary;
  return switch (field) {
    MetadataField.title => summary.title,
    MetadataField.authors =>
      summary.authors.isEmpty ? summary.author : summary.authors.join(', '),
    MetadataField.series => [
      summary.series,
      ?_band(summary.seriesSequence),
    ].whereType<String>().join(' · '),
    MetadataField.year => summary.publishedYear?.toString() ?? '',
    MetadataField.publisher => summary.publisher ?? '',
    MetadataField.language => summary.language ?? '',
    MetadataField.genres => summary.genres.join(', '),
    MetadataField.description => summary.description ?? '',
    MetadataField.cover =>
      summary.hasFolderCover
          ? 'Bild aus dem Ordner'
          : summary.coverPath == null
          ? ''
          : 'vorhanden',
    MetadataField.backdrop => summary.backdropPath == null ? '' : 'vorhanden',
  };
}

/// What the match would put there instead.
String matchValue(MetadataCandidate candidate, MetadataField field) =>
    switch (field) {
      MetadataField.title => candidate.title,
      MetadataField.authors => candidate.authors.join(', '),
      MetadataField.series => [
        candidate.series,
        ?_band(candidate.seriesSequence),
      ].whereType<String>().join(' · '),
      MetadataField.year => candidate.releaseYear?.toString() ?? '',
      MetadataField.publisher => candidate.publisher ?? '',
      MetadataField.language => candidate.language ?? '',
      MetadataField.genres => candidate.genres.join(', '),
      MetadataField.description => candidate.description ?? '',
      MetadataField.cover => 'Bild vom Dienst',
      MetadataField.backdrop => 'Breitbild vom Dienst',
    };

/// „Band 3" statt „Band 3.0" — und „Band 3.5" bleibt, was es ist.
String? _band(double? sequence) {
  if (sequence == null) return null;
  final rounded = sequence.round();
  return 'Band ${sequence == rounded ? '$rounded' : '$sequence'}';
}

class _FieldChoice extends StatelessWidget {
  const _FieldChoice({
    required this.work,
    required this.candidate,
    required this.chosen,
    required this.onToggle,
  });

  final WorkView work;
  final MetadataCandidate candidate;
  final Set<MetadataField> chosen;
  final void Function(MetadataField field, bool on) onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final offered = offeredFields(candidate);
    final blocked = work.summary.hasFolderCover;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '„${candidate.title}" · ${candidate.provider}',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: FundusSpace.x2),
          Text(
            'Nur was hier angehakt ist, wird geschrieben. Alles andere '
            'bleibt, wie es ist.',
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.textFaint),
          ),
          const SizedBox(height: FundusSpace.x2),
          for (final field in MetadataField.values)
            if (offered.contains(field))
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: chosen.contains(field),
                onChanged: field == MetadataField.cover && blocked
                    ? null
                    : (on) => onToggle(field, on ?? false),
                title: Text(field.label),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (currentValue(work, field).trim().isNotEmpty)
                      Text(
                        'Jetzt: ${currentValue(work, field)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: tokens.textFaint,
                        ),
                      ),
                    Text(
                      field == MetadataField.cover && blocked
                          // Ein cover.jpg im Ordner ist eine Entscheidung, die
                          // jemand getroffen hat — kein Treffer überschreibt
                          // sie.
                          ? 'Der Ordner hat ein eigenes Titelbild.'
                          : 'Neu: ${matchValue(candidate, field)}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _MatchRow extends StatelessWidget {
  const _MatchRow({required this.match, required this.onTap});

  final MetadataMatch match;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final candidate = match.candidate;
    final subtitle = [
      candidate.releaseYear?.toString(),
      if (candidate.authors.isNotEmpty) candidate.authors.first,
      candidate.provider,
      ...match.reasons,
    ].whereType<String>().join(' · ');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 44,
        height: 62,
        child: candidate.posterUrl == null
            ? Icon(FundusIcons.book, color: tokens.textFaint)
            : Image.network(
                candidate.posterUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Icon(FundusIcons.warning, color: tokens.textFaint),
              ),
      ),
      title: Text(candidate.title),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Text('${(match.score * 100).round()} %'),
      onTap: onTap,
    );
  }
}
