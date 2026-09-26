import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/work_view.dart';
import '../library/work_poster.dart';
import 'person_credits.dart';

/// Alles von einer Person, quer durch die Bibliotheken.
///
/// Eine Person steht am Werk und nicht am Regal. Wer einen Sprecher antippt,
/// will seine Hörbücher sehen — und wenn derselbe Mensch woanders geschrieben
/// hat, das auch. Zuerst nach Medientyp und darin nach Rolle zu gliedern hält
/// dabei Hörbücher, Filme und Musik auseinander, ohne die Person zu teilen.
class PersonScreen extends StatefulWidget {
  const PersonScreen({super.key, required this.name});

  final String name;

  @override
  State<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends State<PersonScreen> {
  late String _name = widget.name;

  Future<void> _pickImage(BuildContext context) async {
    final scope = FundusScope.of(context);
    final library = scope.library.library;
    if (library == null || library.isReadOnly) return;
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    if (!mounted || result == null || result.files.single.bytes == null) return;
    final picked = result.files.single;
    try {
      await library.cachePersonImage(
        name: _name,
        bytes: picked.bytes!,
        extension: picked.extension ?? 'jpg',
      );
      scope.library.refresh();
      if (mounted) setState(() {});
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Personenbild konnte nicht gespeichert werden: $error'),
        ),
      );
    }
  }

  Future<void> _editProfile(BuildContext context, PersonProfile profile) async {
    final scope = FundusScope.of(context);
    final name = TextEditingController(text: profile.displayName);
    final notes = TextEditingController(text: profile.notes);
    final links = TextEditingController(
      text: profile.externalIds.entries
          .map((entry) => '${entry.key}: ${entry.value}')
          .join('\n'),
    );
    final result =
        await showDialog<({String name, String notes, String links})>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Person bearbeiten'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: name,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                    const SizedBox(height: FundusSpace.x3),
                    TextField(
                      controller: notes,
                      minLines: 3,
                      maxLines: 8,
                      decoration: const InputDecoration(
                        labelText: 'Notizen zur Person',
                      ),
                    ),
                    const SizedBox(height: FundusSpace.x3),
                    TextField(
                      controller: links,
                      minLines: 2,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        labelText: 'Externe Links',
                        helperText: 'Eine Zeile je Link: quelle: URL',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Abbrechen'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop((
                  name: name.text.trim(),
                  notes: notes.text,
                  links: links.text,
                )),
                child: const Text('Speichern'),
              ),
            ],
          ),
        );
    name.dispose();
    notes.dispose();
    links.dispose();
    if (result == null || !context.mounted || result.name.isEmpty) return;
    final externalIds = <String, String>{};
    for (final line in result.links.split('\n')) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      final key = line.substring(0, separator).trim();
      final value = line.substring(separator + 1).trim();
      if (key.isNotEmpty && value.isNotEmpty) externalIds[key] = value;
    }
    try {
      final library = scope.library.library!;
      library.savePersonProfile(
        currentName: profile.displayName,
        displayName: result.name,
        notes: result.notes,
        externalIds: externalIds,
      );
      scope.library.refresh();
      setState(() => _name = result.name);
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final stage = FundusStageSize.of(context);
    final profile =
        scope.library.library?.personProfile(_name) ??
        PersonProfile(id: '', displayName: _name);
    final credits = worksOfPerson(
      _name,
      scope.library.works,
      library: scope.library.library,
    );

    if (credits.isEmpty) {
      return FundusEmptyState(
        icon: FundusIcons.person,
        title: _name,
        reason:
            'Zu dieser Person steht gerade nichts im Katalog. Vielleicht hat '
            'ein Abgleich sie inzwischen anders geschrieben.',
      );
    }

    final byRole = <String, List<WorkView>>{};
    final byMedia = <String, List<({WorkView work, Set<String> roles})>>{};
    for (final entry in credits) {
      byMedia
          .putIfAbsent(entry.work.mediaType?.label ?? 'Weitere Werke', () => [])
          .add(entry);
      for (final role in entry.roles) {
        byRole.putIfAbsent(role, () => []).add(entry.work);
      }
    }

    return ListView(
      padding: EdgeInsets.all(stage.gutter),
      children: [
        Row(
          children: [
            Tooltip(
              message: 'Eigenes Personenbild wählen',
              child: InkWell(
                borderRadius: FundusRadius.mdAll,
                onTap: scope.library.library?.isReadOnly == false
                    ? () => _pickImage(context)
                    : null,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    PersonAvatar(
                      name: profile.displayName,
                      size: 72,
                      imagePath: scope.library.library?.personImage(_name),
                      root: scope.library.library?.root.path,
                    ),
                    if (scope.library.library?.isReadOnly == false)
                      Positioned(
                        right: -6,
                        bottom: -6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: tokens.surface,
                            shape: BoxShape.circle,
                            border: Border.all(color: tokens.divider),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.all(5),
                            child: Icon(Icons.add_a_photo_outlined, size: 16),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: FundusSpace.x4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.displayName,
                    style: theme.textTheme.displaySmall,
                  ),
                  const SizedBox(height: FundusSpace.x1),
                  Text(
                    byRole.keys.join(' · '),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: tokens.textMuted,
                    ),
                  ),
                  const SizedBox(height: FundusSpace.x2),
                  Wrap(
                    spacing: FundusSpace.x2,
                    runSpacing: FundusSpace.x2,
                    children: [
                      ActionChip(
                        avatar: Icon(
                          FundusIcons.filter,
                          size: FundusIcons.sizeSm,
                        ),
                        label: const Text('Alle Werke filtern'),
                        onPressed: () => scope.showPerson(profile.displayName),
                      ),
                      for (final role in byRole.keys)
                        ActionChip(
                          label: Text(role),
                          onPressed: () =>
                              scope.showPerson(profile.displayName, role: role),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Person bearbeiten',
              onPressed: () => _editProfile(context, profile),
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        if (profile.notes.trim().isNotEmpty || profile.externalIds.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: FundusSpace.x4),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(FundusSpace.x4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (profile.notes.trim().isNotEmpty)
                      Text(profile.notes.trim()),
                    if (profile.externalIds.isNotEmpty) ...[
                      if (profile.notes.trim().isNotEmpty)
                        const SizedBox(height: FundusSpace.x2),
                      Wrap(
                        spacing: FundusSpace.x2,
                        children: [
                          for (final entry in profile.externalIds.entries)
                            _ExternalLinkChip(
                              service: entry.key,
                              value: entry.value,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: FundusSpace.x8),
        for (final media in byMedia.entries) ...[
          Text(
            '${media.key.toUpperCase()} · ${media.value.length}',
            style: theme.textTheme.titleSmall?.copyWith(
              color: tokens.textMuted,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: FundusSpace.x3),
          for (final role in _rolesIn(media.value)) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    scope.showPerson(profile.displayName, role: role),
                icon: Icon(FundusIcons.filter, size: FundusIcons.sizeSm),
                label: Text(role),
              ),
            ),
            Wrap(
              spacing: stage.railGap,
              runSpacing: stage.railGap,
              children: [
                for (final credit in media.value)
                  if (credit.roles.contains(role))
                    WorkPoster(
                      work: credit.work,
                      width: stage.posterWidth,
                      onTap: () =>
                          scope.navigation.go(WorkRoute(credit.work.id)),
                    ),
              ],
            ),
            const SizedBox(height: FundusSpace.x4),
          ],
          const SizedBox(height: FundusSpace.x4),
        ],
      ],
    );
  }
}

List<String> _rolesIn(List<({WorkView work, Set<String> roles})> credits) =>
    {for (final credit in credits) ...credit.roles}.toList(growable: false);

class _ExternalLinkChip extends StatelessWidget {
  const _ExternalLinkChip({required this.service, required this.value});

  final String service;
  final String value;

  @override
  Widget build(BuildContext context) {
    final uri = _personLinkUri(service, value);
    final host = uri?.host.replaceFirst('www.', '');
    return ActionChip(
      avatar: const Icon(Icons.open_in_new, size: 16),
      label: Text(
        host == null || host.isEmpty
            ? '$service · $value'
            : '${_serviceLabel(service)} · $host',
      ),
      tooltip: uri?.toString() ?? value,
      onPressed: uri == null ? null : () => launchUrl(uri),
    );
  }
}

Uri? _personLinkUri(String service, String value) {
  final direct = Uri.tryParse(value.trim());
  if (direct != null && (direct.scheme == 'http' || direct.scheme == 'https')) {
    return direct;
  }
  final id = value.trim();
  if (id.isEmpty) return null;
  return switch (service.trim().toLowerCase()) {
    'tmdb' => Uri.parse('https://www.themoviedb.org/person/$id'),
    'imdb' => Uri.parse('https://www.imdb.com/name/$id/'),
    'anilist' => Uri.parse('https://anilist.co/staff/$id'),
    'mal' || 'myanimelist' => Uri.parse('https://myanimelist.net/people/$id'),
    'goodreads' => Uri.parse('https://www.goodreads.com/author/show/$id'),
    'hardcover' => Uri.parse('https://hardcover.app/authors/$id'),
    _ => null,
  };
}

String _serviceLabel(String value) => switch (value.trim().toLowerCase()) {
  'mal' || 'myanimelist' => 'MyAnimeList',
  'tmdb' => 'TMDB',
  'imdb' => 'IMDb',
  'anilist' => 'AniList',
  'goodreads' => 'Goodreads',
  'hardcover' => 'Hardcover',
  _ => value.trim(),
};

/// Die Kachel einer Person: zwei Buchstaben auf einer Fläche.
///
/// Personenbilder führt Fundus nicht — es hat keine, und ein erfundenes
/// Gesicht wäre schlimmer als keines. Die Farbe kommt aus dem Namen, damit
/// dieselbe Person überall gleich aussieht und zwei nebeneinander
/// unterscheidbar sind.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.name,
    this.size = 56,
    this.imagePath,
    this.root,
  });

  final String name;
  final double size;

  /// Der Pfad des Bildes, relativ zur Bibliothek — wo der Abgleich eines
  /// mitgebracht hat.
  final String? imagePath;
  final String? root;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final tint = tokens.accentTint(0.10 + (name.hashCode.abs() % 12) / 100);
    final relative = imagePath;
    final base = root;
    final file = relative == null || base == null
        ? null
        : File(p.join(base, p.joinAll(p.posix.split(relative))));

    return ClipRRect(
      borderRadius: FundusRadius.mdAll,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tint,
          border: Border.fromBorderSide(BorderSide(color: tokens.divider)),
        ),
        // Ein Gesicht, wo eines da ist; sonst ein Platzhalter. Erfunden wird
        // keines — die Anfangsbuchstaben unter dem Zeichen sagen wenigstens,
        // wer gemeint ist.
        child: file != null && file.existsSync()
            ? Image.file(
                file,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) =>
                    _Placeholder(name: name, size: size),
              )
            : _Placeholder(name: name, size: size),
      ),
    );
  }
}

/// Das Platzhalterbild: ein Zeichen und zwei Buchstaben.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          FundusIcons.person,
          size: size / 2.6,
          color: tokens.textFaint.withValues(alpha: 0.7),
        ),
        if (size >= 72) ...[
          SizedBox(height: size / 20),
          Text(
            initialsOf(name),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: tokens.textFaint,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ],
    );
  }
}
