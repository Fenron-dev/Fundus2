import 'dart:math';

import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/media_type.dart';
import '../../data/work_view.dart';
import 'shelf_sections.dart';
import 'work_poster.dart';
import 'work_spotlight.dart';

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
  /// Welche Regale eine Bühne bekommen: alle.
  ///
  /// Sie war für Filme und Serien gedacht und hat sich dort bewährt — aber
  /// „was jetzt?" ist bei Hörbüchern, Mangas und Musik dieselbe Frage, und
  /// eine Wand gleicher Kacheln ist überall ein Dateilisting.
  static bool suits(MediaTypeDefinition? type) => type != null;

  @override
  State<StageScreen> createState() => _StageScreenState();
}

class _StageScreenState extends State<StageScreen> {
  /// The pick is drawn once and kept for as long as the screen is open.
  ///
  /// A suggestion that changes under your hand while you are reading it is
  /// not a suggestion. „Neu würfeln" is the way to change it, on purpose.

  /// Wie viele Werke in einer Reihe stehen. Der Rest ist einen Tipp auf die
  /// Überschrift entfernt.
  static const _railLength = 20;

  List<WorkView> _section(ShelfSection section) => worksInSection(
    section,
    widget.works,
    seed: FundusScope.of(context).suggestionSeed,
    limit: _railLength,
  );

  List<WorkView> get _continuing => _section(ShelfSection.continuing);
  List<WorkView> get _recent => _section(ShelfSection.recent);
  List<WorkView> get _surprise => _section(ShelfSection.surprise);

  WorkView? get _feature {
    if (widget.works.isEmpty) return null;
    // Something unfinished if there is one — that is the likeliest answer to
    // „was jetzt?" — and otherwise a draw from the whole shelf.
    final open = _continuing;
    final pool = open.isEmpty ? widget.works : open;
    return pool[Random(
      FundusScope.of(context).suggestionSeed,
    ).nextInt(pool.length)];
  }

  /// Führt auf die Seite, die diese Reihe ganz zeigt.
  void _showAll(ShelfSection section) => FundusScope.of(
    context,
  ).navigation.go(LibraryRoute(mediaTypeId: widget.type?.id, section: section));

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
            child: WorkSpotlight(
              work: feature,
              stage: stage,
              onOpen: () => widget.onOpen(feature),
              onDetails: () =>
                  FundusScope.of(context).navigation.go(WorkRoute(feature.id)),
              onReroll: FundusScope.of(context).reshuffleSuggestion,
            ),
          ),
        if (continuing.isNotEmpty)
          SliverToBoxAdapter(
            child: _Rail(
              title: ShelfSection.continuing.label,
              works: continuing,
              stage: stage,
              onOpen: widget.onOpen,
              onMore: () => _showAll(ShelfSection.continuing),
            ),
          ),
        SliverToBoxAdapter(
          child: _Rail(
            title: ShelfSection.recent.label,
            works: recent,
            stage: stage,
            onOpen: widget.onOpen,
            onMore: () => _showAll(ShelfSection.recent),
          ),
        ),
        SliverToBoxAdapter(
          child: _Rail(
            title: ShelfSection.surprise.label,
            works: _surprise,
            stage: stage,
            onOpen: widget.onOpen,
            onMore: () => _showAll(ShelfSection.surprise),
            // Auf dem Telefon ist „Neu mischen" ein Zeichen: nebeneinander
            // blieb von der Überschrift „Zufällig en…" übrig.
            action: stage == FundusStageSize.handset
                ? IconButton(
                    onPressed: FundusScope.of(context).reshuffleSuggestion,
                    tooltip: 'Neu mischen',
                    icon: Icon(FundusIcons.shuffle, size: FundusIcons.sizeMd),
                  )
                : TextButton(
                    onPressed: FundusScope.of(context).reshuffleSuggestion,
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
              onMore: () => _showAll(ShelfSection.all),
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

/// One horizontal row of works.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.title,
    required this.works,
    required this.stage,
    required this.onOpen,
    this.action,
    this.onMore,
  });

  final String title;
  final List<WorkView> works;
  final FundusStageSize stage;
  final void Function(WorkView) onOpen;
  final Widget? action;

  /// Die Überschrift führt auf die Seite, die diese Reihe ganz zeigt.
  final VoidCallback? onMore;

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
          child: _RailHeading(title: title, action: action, onMore: onMore),
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
  const _RailHeading({
    required this.title,
    this.count,
    this.action,
    this.onMore,
  });

  final String title;
  final int? count;
  final Widget? action;

  /// Wo die Überschrift hinführt, wenn es mehr gibt als die Reihe zeigt.
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final label = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    return Row(
      children: [
        Flexible(
          child: onMore == null
              ? label
              : InkWell(
                  onTap: onMore,
                  borderRadius: FundusRadius.smAll,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: label),
                      const SizedBox(width: FundusSpace.x1),
                      Icon(
                        FundusIcons.forward,
                        size: FundusIcons.sizeSm,
                        color: tokens.textFaint,
                      ),
                    ],
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
