import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

  /// Ein Feld je Zugangsdatum, nicht je Dienst: die beiden
  /// MyAnimeList-Einträge teilen sich eine Client-ID.
  late final Map<String, TextEditingController> _credentials = {
    for (final key in const ['tmdb', 'hardcover', 'mal'])
      key: TextEditingController(text: widget.settings.credentialFor(key)),
  };
  late final List<MetadataProviderKind> _suggested = [
    ...MetadataProviderKind.forMediaType(widget.work.mediaType?.id),
    if (widget.work.summary.contentSensitivity == 'adult_explicit') ...[
      MetadataProviderKind.anilistAdultAnime,
      MetadataProviderKind.anilistAdultManga,
      MetadataProviderKind.mangaDexAdult,
      MetadataProviderKind.myAnimeListApiAdult,
      MetadataProviderKind.myAnimeListAdult,
    ],
  ];
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
  bool _useIncomingCover = false;
  final Set<MetadataField> _fields = {};
  String? _titleChoice;
  MetadataMergeMode _mergeMode = MetadataMergeMode.complement;

  @override
  void dispose() {
    _query.dispose();
    for (final controller in _credentials.values) {
      controller.dispose();
    }
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
    final credential = _credentialController.text.trim();
    if (_provider.needsKey && credential.isEmpty) {
      setState(
        () => _error =
            'Für ${_provider.label} wird ein eigenes Zugangsdatum benötigt: '
            '${_provider.credentialLabel}, kostenlos unter '
            '${_provider.credentialSource}.',
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    await widget.settings.setCredential(_provider.credentialKey, credential);
    await widget.settings.setMetadataLanguage(_language);
    try {
      final results = await MetadataSearch([
        providerFor(_provider, apiKey: credential),
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

  /// Holt zum gewählten Treffer nach, was die Suche nicht mitschickt.
  ///
  /// Erst jetzt und nicht für alle zehn Treffer: die Besetzung ist eine
  /// zweite Runde übers Netz, und neun davon wären weggeworfen. Kommt sie
  /// nicht, ist der Treffer trotzdem einer.
  Future<MetadataCandidate> _withCredits(MetadataCandidate candidate) async {
    try {
      return await providerFor(
        _provider,
        apiKey: _credentialController.text.trim(),
      ).enrich(candidate);
    } on Object {
      return candidate;
    }
  }

  Future<void> _finish(
    MetadataCandidate chosen,
    Set<MetadataField> fields,
  ) async {
    setState(() => _loading = true);
    final full = await _withCredits(chosen);
    if (!mounted) return;
    setState(() => _loading = false);
    final selected = _titleChoice == null || _titleChoice == full.title
        ? full
        : full.copyWith(
            title: _titleChoice,
            alternateTitles: {
              full.title,
              ...full.alternateTitles,
            }.where((title) => title != _titleChoice).toList(growable: false),
          );
    Navigator.of(context).pop(
      MetadataChoice(
        candidate: selected,
        fields: fields,
        mergeMode: _mergeMode,
        useIncomingCover: _useIncomingCover,
      ),
    );
  }

  void _choose(MetadataCandidate candidate) => setState(() {
    _chosen = candidate;
    _useIncomingCover = widget.work.summary.coverPath == null;
    _titleChoice = candidate.title;
    _fields
      ..clear()
      ..addAll(offeredFields(candidate));
  });

  TextEditingController get _credentialController =>
      _credentials[_provider.credentialKey] ?? _credentials.values.first;

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
            titleChoice: _titleChoice,
            onTitleChoice: (value) => setState(() => _titleChoice = value),
            mergeMode: _mergeMode,
            onMergeMode: (value) => setState(() => _mergeMode = value),
            useIncomingCover: _useIncomingCover,
            onSelectCover: (value) => setState(() {
              _useIncomingCover = value;
              if (value) _fields.add(MetadataField.cover);
            }),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => setState(() => _chosen = null),
            child: const Text('Zurück'),
          ),
          TextButton(
            onPressed: () => unawaited(_finish(chosen, const {})),
            child: const Text('Nur verknüpfen'),
          ),
          FilledButton(
            onPressed: _fields.isEmpty
                ? null
                : () => unawaited(_finish(chosen, {..._fields})),
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
                controller: _credentialController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: _provider.credentialLabel,
                  helperText:
                      'Von ${_provider.credentialSource}. '
                      'Bleibt auf diesem Gerät, nie in der Bibliothek.',
                  border: const OutlineInputBorder(),
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
  if (candidate.tags.isNotEmpty) MetadataField.tags,
  if (candidate.description != null) MetadataField.description,
  if (candidate.posterUrl != null) MetadataField.cover,
  if (candidate.backdropUrl != null) MetadataField.backdrop,
};

/// Labels stay media-aware: a film has a production studio, not a publisher,
/// and it has no manga-style "Reihe & Band" field.
String metadataFieldLabel(MetadataField field, String? workKind) {
  if (field == MetadataField.publisher &&
      (workKind == 'movie' || workKind == 'tv')) {
    return 'Studio / Sender';
  }
  if (field == MetadataField.series && workKind == 'tv') return 'Serie';
  return field.label;
}

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
    MetadataField.tags => '',
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
      MetadataField.tags => candidate.tags.join(', '),
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
    required this.titleChoice,
    required this.onTitleChoice,
    required this.mergeMode,
    required this.onMergeMode,
    required this.useIncomingCover,
    required this.onSelectCover,
  });

  final WorkView work;
  final MetadataCandidate candidate;
  final Set<MetadataField> chosen;
  final void Function(MetadataField field, bool on) onToggle;
  final String? titleChoice;
  final ValueChanged<String> onTitleChoice;
  final MetadataMergeMode mergeMode;
  final ValueChanged<MetadataMergeMode> onMergeMode;
  final bool useIncomingCover;
  final ValueChanged<bool> onSelectCover;

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
          SegmentedButton<MetadataMergeMode>(
            segments: const [
              ButtonSegment(
                value: MetadataMergeMode.complement,
                label: Text('Ergänzen'),
              ),
              ButtonSegment(
                value: MetadataMergeMode.replace,
                label: Text('Überschreiben'),
              ),
            ],
            selected: {mergeMode},
            onSelectionChanged: (values) {
              if (values.isNotEmpty) onMergeMode(values.first);
            },
          ),
          const SizedBox(height: FundusSpace.x2),
          Text(
            'Nur was hier angehakt ist, wird geschrieben. Alles andere '
            'bleibt, wie es ist.',
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.textFaint),
          ),
          const SizedBox(height: FundusSpace.x2),
          if (candidate.alternateTitles.isNotEmpty) ...[
            const Text('HAUPTTITEL'),
            const SizedBox(height: FundusSpace.x1),
            Wrap(
              spacing: FundusSpace.x1,
              children: [
                for (final title in {
                  candidate.title,
                  ...candidate.alternateTitles,
                })
                  ChoiceChip(
                    label: Text(title),
                    selected: title == titleChoice,
                    onSelected: (_) => onTitleChoice(title),
                  ),
              ],
            ),
            const SizedBox(height: FundusSpace.x2),
          ],
          for (final field in MetadataField.values)
            if (offered.contains(field))
              Column(
                children: [
                  if (field == MetadataField.cover &&
                      candidate.posterUrl != null)
                    _ImageComparison(
                      existing: work.summary.coverPath,
                      incoming: candidate.posterUrl!,
                      selected: useIncomingCover,
                      onSelectIncoming: () => onSelectCover(true),
                    ),
                  if (field == MetadataField.cover &&
                      candidate.posterUrl != null)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: useIncomingCover,
                      onChanged: (value) => onSelectCover(value ?? false),
                      title: const Text('Neues Titelbild verwenden'),
                      subtitle: const Text(
                        'Das neue Bild wird auch bei „Ergänzen“ übernommen.',
                      ),
                    ),
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: chosen.contains(field),
                    onChanged: (on) => onToggle(field, on ?? false),
                    title: Text(metadataFieldLabel(field, work.kind)),
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
                              ? 'Ordnerbild vorhanden — neues Bild kann ausdrücklich gewählt werden.'
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
        ],
      ),
    );
  }
}

class _ImageComparison extends StatelessWidget {
  const _ImageComparison({
    required this.existing,
    required this.incoming,
    this.selected = false,
    this.onSelectIncoming,
  });

  final String? existing;
  final String incoming;
  final bool selected;
  final VoidCallback? onSelectIncoming;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: _preview(context, existing, 'Bisher')),
      const SizedBox(width: FundusSpace.x2),
      Expanded(
        child: Column(
          children: [
            InkWell(
              onTap: onSelectIncoming,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: _preview(context, incoming, 'Neu'),
              ),
            ),
            const SizedBox(height: FundusSpace.x1),
            OutlinedButton.icon(
              onPressed: onSelectIncoming,
              icon: Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
              ),
              label: Text(selected ? 'Neues Bild ausgewählt' : 'Neu verwenden'),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _preview(BuildContext context, String? source, String label) {
    final child = source == null
        ? const Icon(Icons.image_not_supported_outlined)
        : source.startsWith('http')
        ? _MatchPoster(url: source)
        : Image.file(File(source), fit: BoxFit.cover);
    return InkWell(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => Dialog(child: InteractiveViewer(child: child)),
      ),
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: Column(
          children: [
            Expanded(child: Center(child: child)),
            Text(label),
          ],
        ),
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
      if (candidate.alternateTitles.isNotEmpty)
        'Alias: ${candidate.alternateTitles.first}',
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
            : _MatchPoster(
                key: ValueKey(candidate.posterUrl),
                url: candidate.posterUrl!,
              ),
      ),
      title: Text(candidate.title),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Text('${(match.score * 100).round()} %'),
      onTap: onTap,
    );
  }
}

/// Previews must use the same verified transport as saved covers. Flutter's
/// Image.network would otherwise still use Dart TLS on Windows.
class _MatchPoster extends StatefulWidget {
  const _MatchPoster({super.key, required this.url});
  final String url;

  @override
  State<_MatchPoster> createState() => _MatchPosterState();
}

class _MatchPosterState extends State<_MatchPoster> {
  late final Future<Uint8List?> _bytes = fetchCoverBytes(widget.url);

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _bytes,
    builder: (context, snapshot) {
      final color = context.fundus.textFaint;
      if (snapshot.data case final bytes?) {
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Icon(FundusIcons.warning, color: color),
        );
      }
      return Icon(
        snapshot.connectionState == ConnectionState.done
            ? FundusIcons.warning
            : FundusIcons.book,
        color: color,
      );
    },
  );
}
