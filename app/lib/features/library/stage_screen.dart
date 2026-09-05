import 'dart:math';

import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/media_type.dart';
import '../../data/work_view.dart';
import 'work_poster.dart';

/// The front of a shelf: one work made large, a few rows, then everything.
///
/// A grid of two hundred equal thumbnails is a file listing. What makes a
/// library of films and series worth opening is that it puts something in
/// front of you — something to watch tonight — and that what you were in the
/// middle of is one reach away. The full grid is still here, at the bottom,
/// where a list belongs once the offers have been made.
///
/// Everything on it is a query over the works already in memory. There is no
/// second index, nothing to keep in step, and nothing here knows whether a
/// work is on this disk or on a machine down the hall.
class StageScreen extends StatefulWidget {
  const StageScreen({
    super.key,
    required this.works,
    required this.type,
    required this.onOpen,
  });

  final List<WorkView> works;
  final MediaTypeDefinition? type;
  final void Function(WorkView) onOpen;

  /// Which shelves get a stage. The others keep the plain grid until their
  /// own arrangement has been thought about.
  static bool suits(MediaTypeDefinition? type) =>
      type != null &&
      (type.id == MediaTypes.movies.id || type.id == MediaTypes.series.id);

  @override
  State<StageScreen> createState() => _StageScreenState();
}

class _StageScreenState extends State<StageScreen> {
  /// The pick is drawn once and kept for as long as the screen is open.
  ///
  /// A suggestion that changes under your hand while you are reading it is
  /// not a suggestion. „Neu würfeln" is the way to change it, on purpose.
  int _seed = DateTime.now().millisecondsSinceEpoch;

  List<WorkView> get _continuing {
    final open = widget.works
        .where((work) => work.hasProgress && !work.finished)
        .toList();
    open.sort((left, right) {
      final leftAt = left.summary.lastListenedAt;
      final rightAt = right.summary.lastListenedAt;
      if (leftAt == null && rightAt == null) return 0;
      if (leftAt == null) return 1;
      if (rightAt == null) return -1;
      return rightAt.compareTo(leftAt);
    });
    return open.take(20).toList(growable: false);
  }

  List<WorkView> get _recent {
    final all = [...widget.works]
      ..sort(
        (left, right) => right.summary.addedAt.compareTo(left.summary.addedAt),
      );
    return all.take(20).toList(growable: false);
  }

  List<WorkView> get _surprise {
    final all = [...widget.works]..shuffle(Random(_seed));
    return all.take(20).toList(growable: false);
  }

  WorkView? get _feature {
    if (widget.works.isEmpty) return null;
    // Something unfinished if there is one — that is the likeliest answer to
    // „was jetzt?" — and otherwise a draw from the whole shelf.
    final open = _continuing;
    final pool = open.isEmpty ? widget.works : open;
    return pool[Random(_seed).nextInt(pool.length)];
  }

  @override
  Widget build(BuildContext context) {
    final stage = FundusStageSize.of(context);
    final feature = _feature;
    final continuing = _continuing;
    final recent = _recent;

    return CustomScrollView(
      slivers: [
        if (feature != null)
          SliverToBoxAdapter(
            child: _Feature(
              work: feature,
              stage: stage,
              onOpen: () => widget.onOpen(feature),
              onDetails: () =>
                  FundusScope.of(context).navigation.go(WorkRoute(feature.id)),
              onReroll: () =>
                  setState(() => _seed = DateTime.now().millisecondsSinceEpoch),
            ),
          ),
        if (continuing.isNotEmpty)
          SliverToBoxAdapter(
            child: _Rail(
              title: 'Weiterschauen',
              works: continuing,
              stage: stage,
              onOpen: widget.onOpen,
            ),
          ),
        SliverToBoxAdapter(
          child: _Rail(
            title: 'Zuletzt hinzugefügt',
            works: recent,
            stage: stage,
            onOpen: widget.onOpen,
          ),
        ),
        SliverToBoxAdapter(
          child: _Rail(
            title: 'Zufällig entdecken',
            works: _surprise,
            stage: stage,
            onOpen: widget.onOpen,
            action: TextButton(
              onPressed: () =>
                  setState(() => _seed = DateTime.now().millisecondsSinceEpoch),
              child: const Text('Neu mischen'),
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            stage.gutter,
            FundusSpace.x6,
            stage.gutter,
            FundusSpace.x3,
          ),
          sliver: SliverToBoxAdapter(
            child: _RailHeading(
              title: 'Alle ${widget.type?.label ?? 'Werke'}',
              count: widget.works.length,
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            stage.gutter,
            0,
            stage.gutter,
            FundusSpace.x16,
          ),
          sliver: _PosterGrid(
            works: widget.works,
            stage: stage,
            onOpen: widget.onOpen,
          ),
        ),
      ],
    );
  }
}

/// The one work the shelf leads with.
class _Feature extends StatelessWidget {
  const _Feature({
    required this.work,
    required this.stage,
    required this.onOpen,
    required this.onDetails,
    required this.onReroll,
  });

  final WorkView work;
  final FundusStageSize stage;
  final VoidCallback onOpen;
  final VoidCallback onDetails;
  final VoidCallback onReroll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final width = MediaQuery.sizeOf(context).width;
    final height = min(width / stage.heroRatio, stage.heroMaxHeight);
    final summary = work.summary;
    final meta = [
      if (summary.publishedYear != null) '${summary.publishedYear}',
      ...summary.genres.take(2),
      work.origin.label,
    ].join(' · ');

    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The artwork is its own background: blown up, blurred, and dimmed
          // into the page so the picture has no edge and the text has a
          // ground dark enough to sit on.
          WorkImage(work: work, blurred: true),
          const DecoratedBox(
            decoration: BoxDecoration(color: Color(0x55000000)),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  tokens.background.withValues(alpha: .1),
                  tokens.background.withValues(alpha: .75),
                  tokens.background,
                ],
                stops: const [0, .62, 1],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              stage.gutter,
              FundusSpace.x6,
              stage.gutter,
              FundusSpace.x6,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // On a wide screen the poster stands beside the text, the way
                // a shelf shows a spine. A phone has no room for both.
                if (stage != FundusStageSize.handset) ...[
                  SizedBox(
                    width: stage.posterWidth,
                    child: WorkArtwork(work: work, showOrigin: false),
                  ),
                  SizedBox(width: stage.gutter),
                ],
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Vorschlag für heute'.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: tokens.accentRamp.s300,
                        ),
                      ),
                      const SizedBox(height: FundusSpace.x2),
                      Text(
                        work.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.displayLarge?.copyWith(
                          fontSize: stage.titleSize,
                          height: 1.1,
                          letterSpacing: -0.5,
                        ),
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: FundusSpace.x2),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: tokens.textMuted,
                          ),
                        ),
                      ],
                      if (summary.description case final description?
                          when stage != FundusStageSize.handset) ...[
                        const SizedBox(height: FundusSpace.x3),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 620),
                          child: Text(
                            description,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: tokens.textMuted,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: FundusSpace.x4),
                      Wrap(
                        spacing: FundusSpace.x3,
                        runSpacing: FundusSpace.x2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.icon(
                            onPressed: work.origin == FundusOrigin.unreachable
                                ? null
                                : onOpen,
                            icon: Icon(
                              FundusIcons.play,
                              size: FundusIcons.sizeSm,
                            ),
                            label: Text(
                              work.hasProgress ? 'Fortsetzen' : 'Abspielen',
                            ),
                          ),
                          OutlinedButton(
                            onPressed: onDetails,
                            child: const Text('Details'),
                          ),
                          IconButton(
                            onPressed: onReroll,
                            tooltip: 'Etwas anderes vorschlagen',
                            icon: Icon(
                              FundusIcons.shuffle,
                              size: FundusIcons.sizeMd,
                            ),
                          ),
                        ],
                      ),
                      if (work.progressLabel case final label?) ...[
                        const SizedBox(height: FundusSpace.x2),
                        Text(
                          label,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: tokens.accentRamp.s300,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One horizontal row of works.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.title,
    required this.works,
    required this.stage,
    required this.onOpen,
    this.action,
  });

  final String title;
  final List<WorkView> works;
  final FundusStageSize stage;
  final void Function(WorkView) onOpen;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    if (works.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            stage.gutter,
            FundusSpace.x6,
            stage.gutter,
            FundusSpace.x3,
          ),
          child: _RailHeading(title: title, action: action),
        ),
        SizedBox(
          // Room for the poster and the two lines under it.
          height: workPosterExtent(
            width: stage.posterWidth,
            textScaler: MediaQuery.textScalerOf(context),
          ),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: stage.gutter),
            itemCount: works.length,
            separatorBuilder: (_, _) => SizedBox(width: stage.railGap),
            itemBuilder: (context, index) => WorkPoster(
              work: works[index],
              width: stage.posterWidth,
              onTap: () => onOpen(works[index]),
            ),
          ),
        ),
      ],
    );
  }
}

class _RailHeading extends StatelessWidget {
  const _RailHeading({required this.title, this.count, this.action});

  final String title;
  final int? count;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    return Row(
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: FundusSpace.x2),
          Text(
            '$count',
            style: theme.textTheme.labelMedium?.copyWith(
              color: tokens.textFaint,
            ),
          ),
        ],
        const Spacer(),
        ?action,
      ],
    );
  }
}

/// The whole shelf, in as many columns as the window allows.
class _PosterGrid extends StatelessWidget {
  const _PosterGrid({
    required this.works,
    required this.stage,
    required this.onOpen,
  });

  final List<WorkView> works;
  final FundusStageSize stage;
  final void Function(WorkView) onOpen;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.crossAxisExtent;
      final columns = max(
        2,
        ((available + stage.railGap) / (stage.posterWidth + stage.railGap))
            .floor(),
      );
      final width = (available - stage.railGap * (columns - 1)) / columns;
      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: FundusSpace.x6,
          crossAxisSpacing: stage.railGap,
          mainAxisExtent: workPosterExtent(
            width: width,
            textScaler: MediaQuery.textScalerOf(context),
          ),
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => WorkPoster(
            work: works[index],
            width: width,
            onTap: () => onOpen(works[index]),
          ),
          childCount: works.length,
        ),
      );
    },
  );
}
