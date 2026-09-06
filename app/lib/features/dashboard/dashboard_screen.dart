import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/media_type.dart';
import '../../data/work_view.dart';
import '../library/unassigned_folders_card.dart';
import '../library/work_poster.dart';
import '../library/work_spotlight.dart';

/// The daily entry point: something to start, then what you were in the
/// middle of, then everything else.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  /// Drawn once and kept while the screen is open. A suggestion that changes
  /// under your hand as you read it is not a suggestion.
  int _seed = DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => FundusScope.of(context).reloadPlaylists(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final stage = FundusStageSize.of(context);
    final works = scope.library.works;

    final continuing =
        works
            .where((work) => work.hasProgress && !work.finished)
            .toList(growable: false)
          ..sort(
            (a, b) => (b.summary.lastListenedAt ?? b.summary.addedAt).compareTo(
              a.summary.lastListenedAt ?? a.summary.addedAt,
            ),
          );
    final recent = works.toList(growable: false)
      ..sort((a, b) => b.summary.addedAt.compareTo(a.summary.addedAt));
    final favourites = works
        .where((work) => work.summary.favourite)
        .toList(growable: false);
    // Was zuletzt lief, nicht was noch offen ist. Ein Film, den man zu Ende
    // gesehen hat, verschwindet aus „Fortsetzen" — und war damit nirgends
    // mehr zu finden, obwohl er das Letzte war, was man gesehen hat.
    final played =
        works
            .where((work) => work.summary.lastListenedAt != null)
            .toList(growable: false)
          ..sort(
            (a, b) =>
                b.summary.lastListenedAt!.compareTo(a.summary.lastListenedAt!),
          );
    // Something to watch, drawn from the whole library rather than from one
    // shelf: a start screen that only ever offers what is already half
    // finished never shows anybody the rest of what they own.
    final picks = _picks(works);

    return ListView(
      padding: EdgeInsets.only(top: stage.gutter, bottom: FundusSpace.x16),
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: stage.gutter),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Greeting(workCount: works.length),
              if (scope.library.isScanning) const _ScanBanner(),
              const UnassignedFoldersCard(),
            ],
          ),
        ),
        if (picks.isNotEmpty) ...[
          const SizedBox(height: FundusSpace.x6),
          _Spotlights(
            picks: picks,
            stage: stage,
            onReroll: () =>
                setState(() => _seed = DateTime.now().millisecondsSinceEpoch),
          ),
        ],
        if (continuing.isNotEmpty) ...[
          _Heading(
            'Fortsetzen',
            hint: scope.settings.peers.isEmpty ? null : 'synchronisiert',
            gutter: stage.gutter,
          ),
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: stage.gutter),
              itemCount: continuing.length.clamp(0, 12),
              separatorBuilder: (_, _) => SizedBox(width: stage.railGap),
              itemBuilder: (context, index) => _ContinueCard(
                key: ValueKey('fortsetzen-${continuing[index].id}'),
                work: continuing[index],
                width: stage == FundusStageSize.handset ? 268.0 : 320.0,
              ),
            ),
          ),
        ],
        if (favourites.isNotEmpty) ...[
          _Heading(
            'Favoriten',
            gutter: stage.gutter,
            action: TextButton(
              onPressed: () {
                scope.setFilter(
                  scope.filter.copyWith(
                    favouritesOnly: true,
                    clearMediaType: true,
                  ),
                );
                scope.navigation.go(const LibraryRoute());
              },
              child: const Text('Alle'),
            ),
          ),
          SizedBox(
            height: workPosterExtent(
              width: stage.posterWidth,
              textScaler: MediaQuery.textScalerOf(context),
            ),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: stage.gutter),
              itemCount: favourites.length.clamp(0, 20),
              separatorBuilder: (_, _) => SizedBox(width: stage.railGap),
              itemBuilder: (context, index) => WorkPoster(
                key: ValueKey('favorit-${favourites[index].id}'),
                work: favourites[index],
                width: stage.posterWidth,
                onTap: () =>
                    scope.navigation.go(WorkRoute(favourites[index].id)),
              ),
            ),
          ),
        ],
        if (scope.playlists.isNotEmpty) ...[
          _Heading(
            'Listen',
            gutter: stage.gutter,
            action: TextButton(
              onPressed: () => scope.navigation.go(const ListsRoute()),
              child: const Text('Alle'),
            ),
          ),
          SizedBox(
            height: 88,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: stage.gutter),
              itemCount: scope.playlists.length.clamp(0, 12),
              separatorBuilder: (_, _) => SizedBox(width: stage.railGap),
              itemBuilder: (context, index) =>
                  _ListCard(list: scope.playlists[index]),
            ),
          ),
        ],
        if (played.isNotEmpty) ...[
          _Heading('Zuletzt gesehen', gutter: stage.gutter),
          SizedBox(
            height: workPosterExtent(
              width: stage.posterWidth,
              textScaler: MediaQuery.textScalerOf(context),
            ),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: stage.gutter),
              itemCount: played.length.clamp(0, 20),
              separatorBuilder: (_, _) => SizedBox(width: stage.railGap),
              itemBuilder: (context, index) => WorkPoster(
                key: ValueKey('gesehen-${played[index].id}'),
                work: played[index],
                width: stage.posterWidth,
                onTap: () => scope.navigation.go(WorkRoute(played[index].id)),
              ),
            ),
          ),
        ],
        if (recent.isEmpty)
          Padding(
            padding: EdgeInsets.all(stage.gutter),
            child: FundusEmptyState(
              title: 'Diese Bibliothek ist noch leer',
              reason:
                  'Es wurde noch nicht gescannt. Der Scan liest den Ordner '
                  'ein und läuft im Hintergrund weiter.',
              action: FilledButton(
                onPressed: scope.library.isScanning ? null : scope.library.scan,
                child: const Text('Jetzt scannen'),
              ),
            ),
          )
        else ...[
          _Heading(
            'Zuletzt hinzugefügt',
            gutter: stage.gutter,
            action: TextButton(
              onPressed: () => scope.openMediaType(null),
              child: const Text('Alle'),
            ),
          ),
          SizedBox(
            height: workPosterExtent(
              width: stage.posterWidth,
              textScaler: MediaQuery.textScalerOf(context),
            ),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: stage.gutter),
              itemCount: recent.length.clamp(0, 20),
              separatorBuilder: (_, _) => SizedBox(width: stage.railGap),
              itemBuilder: (context, index) => WorkPoster(
                work: recent[index],
                width: stage.posterWidth,
                onTap: () => scope.navigation.go(WorkRoute(recent[index].id)),
              ),
            ),
          ),
          _Heading('Medientypen', gutter: stage.gutter),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: stage.gutter),
            child: _MediaTypeGrid(stage: stage),
          ),
        ],
      ],
    );
  }

  /// One suggestion on a phone, two where there is room for two.
  List<WorkView> _picks(List<WorkView> works) {
    if (works.isEmpty) return const [];
    final wanted = FundusStageSize.of(context) == FundusStageSize.handset
        ? 1
        : 2;
    final pool = [...works]..shuffle(Random(_seed));
    return pool.take(wanted.clamp(1, pool.length)).toList(growable: false);
  }
}

/// The big picks at the top of the start screen.
class _Spotlights extends StatelessWidget {
  const _Spotlights({
    required this.picks,
    required this.stage,
    required this.onReroll,
  });

  final List<WorkView> picks;
  final FundusStageSize stage;
  final VoidCallback onReroll;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final height = min(
      width / stage.heroRatio,
      stage.heroMaxHeight,
    ).clamp(240.0, stage.heroMaxHeight);

    Widget spotlight(WorkView work, {bool first = true}) => ClipRRect(
      borderRadius: FundusArtwork.heroRadius,
      child: WorkSpotlight(
        work: work,
        stage: stage,
        height: height,
        kicker: first ? 'Vorschlag für heute' : 'Oder das hier',
        onOpen: () => scope.play(work),
        onDetails: () => scope.navigation.go(WorkRoute(work.id)),
        onReroll: first ? onReroll : null,
      ),
    );

    if (picks.length == 1) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: stage.gutter),
        child: spotlight(picks.first),
      );
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: stage.gutter),
      // The height is given rather than stretched: inside a list there is no
      // top to stretch against, and asking for one is an infinite constraint.
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            Expanded(child: spotlight(picks.first)),
            SizedBox(width: stage.railGap),
            Expanded(child: spotlight(picks[1], first: false)),
          ],
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.workCount});

  final int workCount;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final theme = Theme.of(context);
    final narrow = FundusStageSize.of(context) == FundusStageSize.handset;
    final hour = DateTime.now().hour;
    final greeting = hour < 11
        ? 'Guten Morgen'
        : hour < 18
        ? 'Guten Tag'
        : 'Guten Abend';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                greeting,
                style: theme.textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: FundusSpace.x1),
              Text(
                '${scope.library.displayName} · ${_count(workCount)} Werke',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tokens.textMuted,
                ),
              ),
            ],
          ),
        ),
        if (narrow)
          IconButton(
            onPressed: scope.library.isScanning
                ? scope.library.cancelScan
                : () => _lookForNews(scope),
            tooltip: scope.library.isScanning
                ? 'Abbrechen'
                : 'Nach Neuem sehen',
            icon: Icon(
              scope.library.isScanning ? FundusIcons.close : FundusIcons.sync,
              size: FundusIcons.sizeMd,
            ),
          )
        else
          OutlinedButton.icon(
            onPressed: scope.library.isScanning
                ? scope.library.cancelScan
                : () => _lookForNews(scope),
            icon: Icon(
              scope.library.isScanning ? FundusIcons.close : FundusIcons.sync,
              size: FundusIcons.sizeSm,
            ),
            label: Text(scope.library.isScanning ? 'Abbrechen' : 'Prüfen'),
          ),
      ],
    );
  }

  /// Erst die Stände der anderen Geräte, dann die Suche nach neuen Dateien.
  ///
  /// Beides heißt „nach Neuem sehen", aber das eine dauert einen Wimpernschlag
  /// und beantwortet die Frage, die man beim Hinsehen hat; das andere liest
  /// den Ordner und darf hinterherlaufen.
  static void _lookForNews(FundusScopeState scope) {
    unawaited(scope.catchUpWithPeers());
    unawaited(scope.library.scan());
  }

  /// Twelve thousand works is „12 480", not „12480".
  static String _count(int value) {
    final digits = '$value';
    final buffer = StringBuffer();
    for (var index = 0; index < digits.length; index++) {
      if (index > 0 && (digits.length - index) % 3 == 0) buffer.write(' ');
      buffer.write(digits[index]);
    }
    return buffer.toString();
  }
}

/// A card for something in the middle of being watched or read.
///
/// Wider than it is tall, with the artwork at its head and the remaining time
/// where the eye lands: what this row answers is „wie weit war ich?", and a
/// poster alone does not answer it. Tapping it carries on — that is what the
/// row is called.
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({super.key, required this.work, required this.width});

  final WorkView work;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final type = work.mediaType;

    return SizedBox(
      width: width,
      child: Material(
        color: tokens.surface,
        borderRadius: FundusArtwork.cardRadius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => scope.play(work),
          child: Row(
            children: [
              SizedBox(
                width: 88,
                child: WorkArtwork(
                  work: work,
                  borderRadius: BorderRadius.zero,
                  showOrigin: false,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(FundusSpace.x4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          if (type != null) ...[
                            Icon(
                              type.icon,
                              size: FundusIcons.sizeSm,
                              color: tokens.accentRamp.s300,
                            ),
                            const SizedBox(width: FundusSpace.x2),
                          ],
                          Expanded(
                            child: Text(
                              type?.label.toUpperCase() ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: tokens.accentRamp.s300,
                              ),
                            ),
                          ),
                          FundusOriginMark(work.origin),
                        ],
                      ),
                      const SizedBox(height: FundusSpace.x2),
                      Text(
                        work.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      if (work.subtitle.isNotEmpty)
                        Text(
                          work.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: tokens.textFaint,
                          ),
                        ),
                      const SizedBox(height: FundusSpace.x2),
                      Text(
                        work.progressLabel ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: tokens.accentRamp.s200,
                        ),
                      ),
                      const SizedBox(height: FundusSpace.x2),
                      ClipRRect(
                        borderRadius: FundusRadius.smAll,
                        child: FundusProgressBar(
                          fraction: work.progressFraction ?? 0,
                          finished: work.finished,
                          height: 3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The shelves, with how much is on each.
/// Eine Liste als Karte — Name und wie viel drinsteht.
class _ListCard extends StatelessWidget {
  const _ListCard({required this.list});

  final LibraryPlaylist list;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;

    return SizedBox(
      width: 220,
      child: Material(
        color: tokens.surface,
        borderRadius: FundusRadius.mdAll,
        child: InkWell(
          borderRadius: FundusRadius.mdAll,
          onTap: () => scope.navigation.go(ListRoute(list.id)),
          child: Padding(
            padding: const EdgeInsets.all(FundusSpace.x3),
            child: Row(
              children: [
                Icon(FundusIcons.lists, color: tokens.accent),
                const SizedBox(width: FundusSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        list.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        list.entries.isEmpty
                            ? 'Noch leer'
                            : '${list.entries.length} Einträge',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: tokens.textFaint,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MediaTypeGrid extends StatelessWidget {
  const _MediaTypeGrid({required this.stage});

  final FundusStageSize stage;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final counts = scope.library.worksPerMediaType;
    final types = [
      for (final type in MediaTypes.ordered(scope.settings.mediaTypeOrder))
        if ((counts[type.id] ?? 0) > 0) type,
    ];
    if (types.isEmpty) return const SizedBox.shrink();
    final columns = switch (stage) {
      FundusStageSize.handset => 2,
      FundusStageSize.tablet => 3,
      FundusStageSize.desktop => 4,
    };

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: stage.railGap,
        crossAxisSpacing: stage.railGap,
        mainAxisExtent: 74,
      ),
      itemCount: types.length,
      itemBuilder: (context, index) {
        final type = types[index];
        return _MediaTypeCard(
          type: type,
          count: counts[type.id] ?? 0,
          onTap: () => scope.openMediaType(type.id),
        );
      },
    );
  }
}

class _MediaTypeCard extends StatelessWidget {
  const _MediaTypeCard({
    required this.type,
    required this.count,
    required this.onTap,
  });

  final MediaTypeDefinition type;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    return Material(
      color: tokens.surface,
      borderRadius: FundusArtwork.cardRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: FundusArtwork.cardRadius,
        child: Padding(
          padding: const EdgeInsets.all(FundusSpace.x4),
          child: Row(
            children: [
              Icon(
                type.icon,
                size: FundusIcons.sizeLg,
                color: tokens.textMuted,
              ),
              const SizedBox(width: FundusSpace.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      type.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      '$count',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: tokens.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanBanner extends StatelessWidget {
  const _ScanBanner();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final progress = scope.library.scanProgress;
    if (progress == null) return const SizedBox.shrink();

    final phase = switch (progress.phase) {
      LibraryIndexPhase.scanning => 'Dateien werden gelesen',
      LibraryIndexPhase.importing => 'Werke werden zugeordnet',
      LibraryIndexPhase.completed => 'Fertig',
      LibraryIndexPhase.cancelled => 'Abgebrochen',
    };

    return Container(
      margin: const EdgeInsets.only(top: FundusSpace.x4),
      padding: const EdgeInsets.all(FundusSpace.x4),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: FundusArtwork.cardRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$phase · ${progress.fileCount} Dateien',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: FundusSpace.x3),
          // Without a total the scan cannot honestly show a percentage.
          ClipRRect(
            borderRadius: FundusRadius.smAll,
            child: const LinearProgressIndicator(minHeight: 3),
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.title, {required this.gutter, this.hint, this.action});

  final String title;
  final double gutter;
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        FundusSpace.x8,
        gutter,
        FundusSpace.x3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              title.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          if (hint case final hint?) ...[
            const SizedBox(width: FundusSpace.x3),
            Text(
              hint,
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
            ),
          ],
          const Spacer(),
          ?action,
        ],
      ),
    );
  }
}
