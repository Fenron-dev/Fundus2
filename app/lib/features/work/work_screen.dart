import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';
import '../../media/reader_controller.dart';
import '../../data/media_type.dart';
import '../../data/work_view.dart';
import '../library/work_cover.dart';

/// One work detail screen for every media type.
///
/// A hero plus building blocks — list, key-value, notes, devices — filled
/// differently per type. A new media type is a field and tab definition; if it
/// needed a new screen, the abstraction would be wrong.
class WorkScreen extends StatelessWidget {
  const WorkScreen({super.key, required this.workId});

  final String workId;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final work = scope.library.workById(workId);
    if (work == null) {
      return const FundusEmptyState(
        title: 'Werk nicht gefunden',
        reason:
            'Es wurde seit dem Öffnen dieser Ansicht entfernt oder neu '
            'indexiert.',
      );
    }

    final tabs =
        work.mediaType?.tabs ?? const [WorkTab.files, WorkTab.properties];
    return DefaultTabController(
      length: tabs.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Hero(work: work),
          _TabBar(tabs: tabs),
          Expanded(
            child: TabBarView(
              children: [
                for (final tab in tabs) _TabContent(work: work, tab: tab),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.work});

  final WorkView work;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(FundusSpace.x10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 132, child: WorkCover(work: work)),
          const SizedBox(width: FundusSpace.x8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (work.mediaType?.label ?? 'Nicht zugeordnet').toUpperCase(),
                  style: theme.textTheme.labelSmall,
                ),
                const SizedBox(height: FundusSpace.x2),
                Text(work.title, style: theme.textTheme.displayLarge),
                if (work.subtitle.isNotEmpty) ...[
                  const SizedBox(height: FundusSpace.x2),
                  Text(
                    work.subtitle,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: tokens.textMuted,
                    ),
                  ),
                ],
                const SizedBox(height: FundusSpace.x4),
                Row(
                  children: [
                    FundusOriginMark(work.origin, showLabel: true),
                    const SizedBox(width: FundusSpace.x6),
                    if (work.summary.fileCount > 0)
                      Text(
                        '${work.summary.fileCount} Dateien',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: tokens.textFaint,
                        ),
                      ),
                  ],
                ),
                if (work.hasProgress) ...[
                  const SizedBox(height: FundusSpace.x4),
                  SizedBox(
                    width: 320,
                    child: FundusProgress(
                      fraction: work.progressFraction!,
                      label: work.progressLabel,
                      finished: work.finished,
                    ),
                  ),
                ],
                const SizedBox(height: FundusSpace.x6),
                Row(
                  children: [
                    FilledButton.icon(
                      // Only what can be reached offers to play; everything
                      // else says why, rather than doing nothing.
                      onPressed: work.origin == FundusOrigin.unreachable
                          ? null
                          : () => FundusScope.of(context).play(work),
                      // Ein Abspielpfeil auf einem Manga verspricht das
                      // Falsche; gelesen wird, nicht abgespielt.
                      icon: Icon(
                        ReaderController.handles(work)
                            ? FundusIcons.manga
                            : FundusIcons.play,
                        size: FundusIcons.sizeSm,
                      ),
                      label: Text(work.hasProgress ? 'Fortsetzen' : 'Öffnen'),
                    ),
                    const SizedBox(width: FundusSpace.x3),
                    if (work.summary.tags.isNotEmpty)
                      Wrap(
                        spacing: FundusSpace.x2,
                        children: [
                          for (final tag in work.summary.tags.take(5))
                            FundusTag(tag),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.tabs});

  final List<WorkTab> tabs;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.divider)),
      ),
      child: TabBar(
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        indicatorColor: tokens.accent,
        dividerColor: Colors.transparent,
        labelColor: tokens.text,
        unselectedLabelColor: tokens.textMuted,
        labelStyle: Theme.of(context).textTheme.bodyMedium,
        tabs: [for (final tab in tabs) Tab(text: tab.label, height: 40)],
      ),
    );
  }
}

class _TabContent extends StatelessWidget {
  const _TabContent({required this.work, required this.tab});

  final WorkView work;
  final WorkTab tab;

  @override
  Widget build(BuildContext context) {
    return switch (tab) {
      WorkTab.properties => _Properties(work: work),
      WorkTab.notes => _Notes(work: work),
      WorkTab.devices => _Devices(work: work),
      WorkTab.files ||
      WorkTab.chapters ||
      WorkTab.episodes ||
      WorkTab.volumes => _Files(work: work),
      WorkTab.cast => _People(work: work),
      WorkTab.related || WorkTab.extras => const FundusEmptyState(
        title: 'Nichts verknüpft',
        reason:
            'Verwandte Werke entstehen aus Reihe, Person und Sammlung — für '
            'dieses Werk ist noch keine dieser Verbindungen erfasst.',
      ),
    };
  }
}

class _Properties extends StatelessWidget {
  const _Properties({required this.work});

  final WorkView work;

  @override
  Widget build(BuildContext context) {
    final summary = work.summary;
    final entries = <(String, String)>[
      ('Titel', summary.title),
      if (summary.authors.isNotEmpty) ('Urheber', summary.authors.join(', ')),
      if (summary.narrators.isNotEmpty)
        ('Sprecher', summary.narrators.join(', ')),
      if (summary.series != null) ('Reihe', summary.series!),
      if (summary.publisher != null) ('Verlag', summary.publisher!),
      if (summary.publishedYear != null) ('Jahr', '${summary.publishedYear}'),
      if (summary.language != null) ('Sprache', summary.language!),
      if (summary.genres.isNotEmpty) ('Genres', summary.genres.join(', ')),
      ('Medientyp', work.mediaType?.label ?? 'Nicht zugeordnet'),
      ('Technischer Grundtyp', summary.kind),
      ('Herkunft', work.origin.label),
      ('Dateien', '${summary.fileCount}'),
      ('Aufgenommen', _formatDate(summary.addedAt)),
    ];

    return ListView(
      padding: const EdgeInsets.all(FundusSpace.x10),
      children: [
        for (final entry in entries) _KeyValueRow(entry.$1, entry.$2),
        if (summary.description != null) ...[
          const SizedBox(height: FundusSpace.x8),
          Text(
            summary.description!,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ],
    );
  }

  static String _formatDate(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}.'
      '${value.month.toString().padLeft(2, '0')}.${value.year}';
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Padding(
      padding: const EdgeInsets.only(bottom: FundusSpace.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 190,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tokens.textFaint),
            ),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _Files extends StatefulWidget {
  const _Files({required this.work});

  final WorkView work;

  @override
  State<_Files> createState() => _FilesState();
}

class _FilesState extends State<_Files> {
  List<LibraryPlaybackTrack>? _tracks;
  String? _failure;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reading the scope needs an inherited widget, which is not available in
    // initState.
    _load();
  }

  void _load() {
    final library = FundusScope.of(context).library.library;
    if (library == null) return;
    try {
      final tracks = library.playbackTracks(widget.work.id);
      setState(() => _tracks = tracks);
    } on Object catch (failure) {
      setState(() => _failure = failure.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final tracks = _tracks;
    if (_failure != null) {
      return FundusEmptyState(
        title: 'Dateien nicht lesbar',
        reason: _failure!,
        icon: FundusIcons.warning,
      );
    }
    if (tracks == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tracks.isEmpty) {
      return const FundusEmptyState(
        title: 'Keine Inhaltsdateien',
        reason:
            'Zu diesem Werk sind keine abspielbaren oder lesbaren Dateien '
            'erfasst. Ein erneuter Scan holt sie, falls sie da sind.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: FundusSpace.x3),
      itemCount: tracks.length,
      itemBuilder: (context, index) {
        final track = tracks[index];
        return Container(
          height: tokens.density.rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: FundusSpace.x10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tokens.divider)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 34,
                child: Text(
                  '${index + 1}',
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
                ),
              ),
              Expanded(
                child: Text(
                  track.title,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              if (track.duration != null)
                Text(
                  _formatDuration(track.duration!),
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _formatDuration(Duration value) {
    final hours = value.inHours;
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _Notes extends StatelessWidget {
  const _Notes({required this.work});

  final WorkView work;

  @override
  Widget build(BuildContext context) {
    final library = FundusScope.of(context).library.library;
    if (library == null) return const SizedBox.shrink();
    final annotations = library.loadAnnotations(work.id);
    final tokens = context.fundus;

    if (annotations.notes.isEmpty && annotations.bookmarks.isEmpty) {
      return const FundusEmptyState(
        title: 'Noch keine Notizen',
        reason:
            'Notizen und Lesezeichen gehören dem Werk und liegen als Klartext '
            'neben den Dateien — sie überleben einen Index-Neuaufbau.',
        icon: null,
      );
    }

    return ListView(
      padding: const EdgeInsets.all(FundusSpace.x10),
      children: [
        if (annotations.bookmarks.isNotEmpty) ...[
          Text('LESEZEICHEN', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: FundusSpace.x3),
          for (final bookmark in annotations.bookmarks)
            Padding(
              padding: const EdgeInsets.only(bottom: FundusSpace.x2),
              child: Row(
                children: [
                  FundusTag(
                    bookmark.displayPosition,
                    tone: FundusTagTone.accent,
                  ),
                  const SizedBox(width: FundusSpace.x3),
                  Expanded(
                    child: Text(
                      bookmark.label ?? bookmark.note ?? 'Ohne Beschriftung',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: FundusSpace.x8),
        ],
        if (annotations.notes.isNotEmpty) ...[
          Text('NOTIZEN', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: FundusSpace.x3),
          for (final note in annotations.notes)
            Container(
              margin: const EdgeInsets.only(bottom: FundusSpace.x3),
              padding: const EdgeInsets.all(FundusSpace.x4),
              decoration: BoxDecoration(
                color: tokens.surface,
                borderRadius: FundusRadius.mdAll,
                border: Border.fromBorderSide(
                  BorderSide(color: tokens.divider),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formatDate(note.createdAt),
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
                  ),
                  const SizedBox(height: FundusSpace.x2),
                  Text(
                    note.markdown,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  static String _formatDate(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}.'
      '${value.month.toString().padLeft(2, '0')}.${value.year}';
}

class _People extends StatelessWidget {
  const _People({required this.work});

  final WorkView work;

  @override
  Widget build(BuildContext context) {
    final people = <(String, String)>[
      for (final author in work.summary.authors) (author, 'Urheber'),
      for (final narrator in work.summary.narrators) (narrator, 'Sprecher'),
    ];
    if (people.isEmpty) {
      return const FundusEmptyState(
        title: 'Keine Personen erfasst',
        reason:
            'Personen entstehen beim Import aus Metadaten; von Hand ergänzte '
            'Angaben bleiben bei späteren Scans geschützt.',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(FundusSpace.x10),
      children: [
        for (final person in people)
          ListTile(
            leading: Icon(FundusIcons.person, size: FundusIcons.sizeLg),
            title: Text(person.$1),
            subtitle: Text(person.$2),
          ),
      ],
    );
  }
}

class _Devices extends StatefulWidget {
  const _Devices({required this.work});

  final WorkView work;

  @override
  State<_Devices> createState() => _DevicesState();
}

class _DevicesState extends State<_Devices> {
  Future<List<DeviceProfile>>? _profiles;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Created once: a future built inside build() restarts on every rebuild.
    _profiles ??= FundusScope.of(context).library.library?.listDeviceProfiles();
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final profiles = _profiles;
    if (profiles == null) return const SizedBox.shrink();

    return FutureBuilder<List<DeviceProfile>>(
      future: profiles,
      builder: (context, snapshot) {
        final profiles = snapshot.data ?? const <DeviceProfile>[];
        if (profiles.isEmpty) {
          return const FundusEmptyState(
            title: 'Nur dieses Gerät',
            reason:
                'Sobald ein zweites Gerät dieselbe Bibliothek öffnet, steht '
                'hier dessen Stand für dieses Werk.',
            icon: null,
          );
        }
        return ListView(
          padding: const EdgeInsets.all(FundusSpace.x10),
          children: [
            for (final profile in profiles)
              ListTile(
                leading: Icon(FundusIcons.devices, size: FundusIcons.sizeLg),
                title: Text(profile.displayName),
                subtitle: Text(
                  profile.key == scope.settings.deviceKey
                      ? 'Dieses Gerät'
                      : profile.platform.isEmpty
                      ? 'Anderes Gerät'
                      : profile.platform,
                ),
              ),
          ],
        );
      },
    );
  }
}
