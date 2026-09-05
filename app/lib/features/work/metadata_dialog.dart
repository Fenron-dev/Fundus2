import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_settings.dart';
import '../../data/work_view.dart';
import '../../metadata/metadata_providers.dart';

/// Searches a work's details and returns what was picked.
///
/// The query starts as the work's own title, because that is what somebody
/// would type. Nothing is applied from here — the dialog answers with a
/// candidate and the caller writes it, so the same dialog serves one work and
/// a whole shelf.
Future<MetadataCandidate?> showMetadataDialog(
  BuildContext context, {
  required WorkView work,
  required AppSettings settings,
}) => showDialog<MetadataCandidate>(
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
  late MetadataProviderKind _provider = MetadataProviderKind.forMediaType(
    widget.work.mediaType?.id,
  ).first;
  late String _language = widget.settings.metadataLanguage;
  bool _loading = false;
  String? _error;
  List<MetadataMatch> _matches = const [];

  @override
  void dispose() {
    _query.dispose();
    _key.dispose();
    super.dispose();
  }

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;

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
              children: [
                for (final kind in MetadataProviderKind.values)
                  ChoiceChip(
                    selected: _provider == kind,
                    onSelected: _loading
                        ? null
                        : (_) => setState(() => _provider = kind),
                    label: Text(kind.label),
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
                  itemBuilder: (context, index) =>
                      _MatchRow(match: _matches[index]),
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

class _MatchRow extends StatelessWidget {
  const _MatchRow({required this.match});

  final MetadataMatch match;

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
      onTap: () => Navigator.of(context).pop(candidate),
    );
  }
}
