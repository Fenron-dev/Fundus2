import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/media_type.dart';
import '../../data/work_filter.dart';
import '../../data/work_view.dart';
import '../lists/lists_screen.dart';
import '../work/batch_editor.dart';
import '../work/bulk_metadata.dart';
import 'shelf_sections.dart';
import 'stage_screen.dart';
import 'work_grid.dart';
import 'work_poster.dart';
import 'work_row.dart';

/// The one library view.
///
/// It does not branch on where a work came from — origin is a column and a
/// filter. The "Ordnen nach" switch lays the same works out differently;
/// filters keep applying in every one of them, the folder view included.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.route});

  final LibraryRoute route;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  /// Die ausgewählten Werke, solange ausgewählt wird. Leer heißt: es wird
  /// nicht ausgewählt, und ein Tipp öffnet wieder.
  final _selected = <String>{};

  LibraryRoute get route => widget.route;

  void _toggle(WorkView work) => setState(() {
    if (!_selected.remove(work.id)) _selected.add(work.id);
  });

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final type = route.mediaTypeId == null
        ? null
        : MediaTypes.byId(route.mediaTypeId!);
    final filter = scope.filter;
    // Eine Reihe von der Bühne, ganz: dieselben Werke, nur in der Ordnung,
    // die ihre Überschrift versprochen hat.
    final section = route.section;
    final works = section == null
        ? filter.apply(scope.library.works)
        : worksInSection(
            section,
            filter.apply(scope.library.works),
            seed: scope.suggestionSeed,
          );

    final grouping = filter.grouping;
    final groupings =
        type?.groupings ??
        const [GroupingMode.tiles, GroupingMode.table, GroupingMode.folder];

    // Vor einem Regal steht der Vorschlag, nicht das Werkzeug.
    //
    // „Ordnen nach" und die Filterleiste gehören zu einer Liste; über einer
    // Bühne sind sie zwei Zeilen, die niemand gerade braucht — auf einem
    // Telefon ist das der halbe Bildschirm. Sie stehen deshalb dort, wo eine
    // Liste steht: hinter „Alle Filme", „Zuletzt hinzugefügt", einer Gruppe
    // oder einer Suche. Auf dem Schreibtisch ist Platz genug, dort bleiben
    // sie stehen.
    final onStage = _showsStage(context, scope, type);
    final tools =
        !onStage || FundusStageSize.of(context) != FundusStageSize.handset;
    final sourceGroups = _sourceGroups(scope, works, grouping, filter);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tools)
          _GroupingBar(
            // Auf der Bühne trägt die Pfadleiste oben den Namen schon; ihn
            // hier zu wiederholen ist eine Zeile für nichts.
            title: onStage
                ? null
                : section == null
                ? (type?.label ?? 'Alle Werke')
                : '${section.label} · ${type?.label ?? 'Alle Werke'}',
            count: onStage ? null : works.length,
            groupings: groupings,
            selected: grouping,
            onSelect: (mode) =>
                scope.setFilter(filter.copyWith(grouping: mode)),
            onMatchAll: works.isEmpty
                ? null
                : () => unawaited(_matchAll(context, scope, works)),
          ),
        if (tools) _ShelfBar(works: scope.library.works),
        Expanded(
          child: works.isEmpty
              ? _empty(context, scope)
              : sourceGroups != null
              ? _sourceBody(context, sourceGroups, grouping)
              : _body(context, scope, works, grouping, type),
        ),
        if (_selected.isNotEmpty)
          _SelectionBar(
            works: [
              for (final work in works)
                if (_selected.contains(work.id)) work,
            ],
            onClear: () => setState(_selected.clear),
            onSelectAll: () => setState(() {
              _selected
                ..clear()
                ..addAll(works.map((work) => work.id));
            }),
          ),
      ],
    );
  }

  /// Plex-like sections for a combined shell catalogue. The normal one-source
  /// view and all drilled-in/search views keep their existing layout; source
  /// sections appear only on the top-level shelf where they add orientation.
  List<({String name, List<WorkView> works})>? _sourceGroups(
    FundusScopeState scope,
    List<WorkView> works,
    GroupingMode grouping,
    WorkFilter filter,
  ) {
    if (grouping != GroupingMode.tiles && grouping != GroupingMode.table) {
      return null;
    }
    if (route.section != null ||
        route.group != null ||
        route.subgroup != null) {
      return null;
    }
    if (filter.text.trim().isNotEmpty) return null;
    final names = {
      for (final source in scope.library.sources) source.id: source.displayName,
    };
    final grouped = <String, List<WorkView>>{};
    for (final work in works) {
      grouped.putIfAbsent(work.summary.sourceId, () => []).add(work);
    }
    if (grouped.length < 2) return null;
    final result = [
      for (final entry in grouped.entries)
        (
          name: names[entry.key] ?? 'Bibliothek',
          works: List<WorkView>.unmodifiable(entry.value),
        ),
    ];
    result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return result;
  }

  Widget _sourceBody(
    BuildContext context,
    List<({String name, List<WorkView> works})> groups,
    GroupingMode grouping,
  ) {
    final stage = FundusStageSize.of(context);
    final compact = context.fundus.density == FundusDensity.compact;
    final target = compact ? stage.posterWidth * .78 : stage.posterWidth;
    final margin = EdgeInsets.fromLTRB(
      stage.gutter,
      FundusSpace.x4,
      stage.gutter,
      FundusSpace.x10,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - margin.horizontal;
        final columns = ((available + stage.railGap) / (target + stage.railGap))
            .floor()
            .clamp(2, 12);
        final width = (available - stage.railGap * (columns - 1)) / columns;
        final extent = workPosterExtent(
          width: width,
          textScaler: MediaQuery.textScalerOf(context),
        );
        return CustomScrollView(
          slivers: [
            for (final group in groups) ...[
              SliverToBoxAdapter(
                child: _SourceSectionHeader(
                  name: group.name,
                  count: group.works.length,
                ),
              ),
              if (grouping == GroupingMode.tiles)
                SliverPadding(
                  padding: margin,
                  sliver: SliverGrid(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => WorkPoster(
                        work: group.works[index],
                        width: width,
                        selected: _selected.contains(group.works[index].id),
                        onTap: () => _selected.isEmpty
                            ? FundusScope.of(
                                context,
                              ).navigation.go(WorkRoute(group.works[index].id))
                            : _toggle(group.works[index]),
                        onLongPress: () => _toggle(group.works[index]),
                      ),
                      childCount: group.works.length,
                    ),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: FundusSpace.x6,
                      crossAxisSpacing: stage.railGap,
                      mainAxisExtent: extent,
                    ),
                  ),
                )
              else
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => WorkRow(
                      work: group.works[index],
                      selected: _selected.contains(group.works[index].id),
                      onTap: () => _selected.isEmpty
                          ? FundusScope.of(
                              context,
                            ).navigation.go(WorkRoute(group.works[index].id))
                          : _toggle(group.works[index]),
                      onLongPress: () => _toggle(group.works[index]),
                    ),
                    childCount: group.works.length,
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  /// Ob hier die Bühne steht statt einer Liste.
  ///
  /// Auf einer Reihe steht die Reihe, in einer Gruppe die Gruppe, und wer
  /// sucht, will die Antwort und keinen Vorschlag.
  bool _showsStage(
    BuildContext context,
    FundusScopeState scope,
    MediaTypeDefinition? type,
  ) =>
      StageScreen.suits(type) &&
      route.section == null &&
      route.group == null &&
      scope.filter.text.isEmpty &&
      scope.filter.grouping == GroupingMode.tiles;

  /// Fetching details for everything in view.
  ///
  /// Here rather than in a settings page: a shelf where the covers are
  /// missing is looked at, and this is where somebody looking at it is.
  Future<void> _matchAll(
    BuildContext context,
    FundusScopeState scope,
    List<WorkView> works,
  ) async {
    final vault = scope.library.library;
    if (vault == null || vault.isReadOnly) return;
    await showBulkMetadata(
      context,
      works: works,
      library: vault,
      settings: scope.settings,
      onChanged: scope.library.refresh,
      mediaTypeId: route.mediaTypeId,
    );
  }

  Widget _empty(BuildContext context, FundusScopeState scope) {
    final hasWorks = scope.library.works.isNotEmpty;
    return FundusEmptyState(
      title: hasWorks ? 'Keine Treffer' : 'Noch nichts indexiert',
      reason: scope.filter.emptyReason(),
      action: hasWorks
          ? OutlinedButton(
              onPressed: () => scope.setFilter(
                WorkFilter(
                  mediaTypeId: scope.filter.mediaTypeId,
                  sort: scope.filter.sort,
                  grouping: scope.filter.grouping,
                ),
              ),
              child: const Text('Filter zurücksetzen'),
            )
          : FilledButton(
              onPressed: scope.library.isScanning ? null : scope.library.scan,
              child: const Text('Bibliothek scannen'),
            ),
    );
  }

  Widget _body(
    BuildContext context,
    FundusScopeState scope,
    List<WorkView> works,
    GroupingMode grouping,
    MediaTypeDefinition? type,
  ) {
    void open(WorkView work) => scope.navigation.go(WorkRoute(work.id));

    if (grouping == GroupingMode.tiles) {
      // A shelf of films or series leads with something to watch rather than
      // with a wall of equal thumbnails. Drilled into a group, or filtered
      // down to a search, the stage would be in the way of the answer.
      if (_showsStage(context, scope, type)) {
        return StageScreen(works: works, type: type, onOpen: open);
      }
      return WorkGrid(
        works: works,
        onOpen: open,
        selected: _selected,
        onSelect: _toggle,
      );
    }
    if (grouping == GroupingMode.table) {
      return ListView.builder(
        itemCount: works.length,
        itemBuilder: (context, index) => WorkRow(
          work: works[index],
          selected: _selected.contains(works[index].id),
          onTap: () =>
              _selected.isEmpty ? open(works[index]) : _toggle(works[index]),
          onLongPress: () => _toggle(works[index]),
        ),
      );
    }

    // A group was opened: show its works, nothing else.
    final openGroup = route.group;
    if (openGroup != null) {
      final group = WorkGrouping.group(
        works,
        grouping,
      ).where((entry) => entry.label == openGroup).firstOrNull;
      final inGroup = group?.works ?? const <WorkView>[];
      if (grouping != GroupingMode.author) {
        return WorkGrid(works: inGroup, onOpen: open);
      }
      return _authorShelf(context, scope, inGroup, open);
    }

    final groups = WorkGrouping.group(works, grouping);
    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (context, index) => _GroupRow(
        group: groups[index],
        onTap: () => scope.navigation.go(
          LibraryRoute(
            mediaTypeId: route.mediaTypeId,
            group: groups[index].label,
          ),
        ),
      ),
    );
  }

  /// One author's shelf: their series, then the books that stand alone.
  ///
  /// This is the step „Urheber" was missing. Grouping by author landed on a
  /// flat wall of every volume they ever wrote, with the seven parts of one
  /// series lying beside the three of another and nothing saying which was
  /// which. A series is one row here, and opening it gives its volumes in
  /// their own order — which is the order a series is read in, not the
  /// alphabet.
  Widget _authorShelf(
    BuildContext context,
    FundusScopeState scope,
    List<WorkView> works,
    void Function(WorkView) open,
  ) {
    final openSeries = route.subgroup;
    if (openSeries != null) {
      final volumes =
          works.where((work) => work.summary.series == openSeries).toList()
            ..sort(_bySequence);
      return WorkGrid(works: volumes, onOpen: open);
    }

    final series = <String, List<WorkView>>{};
    final loose = <WorkView>[];
    for (final work in works) {
      final name = work.summary.series?.trim();
      if (name == null || name.isEmpty) {
        loose.add(work);
      } else {
        series.putIfAbsent(name, () => []).add(work);
      }
    }
    final names = series.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    if (names.isEmpty) {
      return WorkGrid(works: loose..sort(_bySequence), onOpen: open);
    }

    return ListView(
      children: [
        for (final name in names)
          _GroupRow(
            group: WorkGroup(label: name, works: series[name]!),
            onTap: () => scope.navigation.go(
              LibraryRoute(
                mediaTypeId: route.mediaTypeId,
                group: route.group,
                subgroup: name,
              ),
            ),
          ),
        if (loose.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              FundusSpace.x6,
              FundusSpace.x6,
              FundusSpace.x6,
              FundusSpace.x2,
            ),
            child: Text(
              'Einzeln',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          for (final work in loose..sort(_bySequence))
            WorkRow(work: work, onTap: () => open(work)),
        ],
      ],
    );
  }

  /// Volumes go in the order they were written, not the order of the alphabet.
  static int _bySequence(WorkView left, WorkView right) {
    final leftNumber = left.summary.seriesSequence;
    final rightNumber = right.summary.seriesSequence;
    if (leftNumber != null &&
        rightNumber != null &&
        leftNumber != rightNumber) {
      return leftNumber.compareTo(rightNumber);
    }
    if (leftNumber != null && rightNumber == null) return -1;
    if (leftNumber == null && rightNumber != null) return 1;
    return left.title.toLowerCase().compareTo(right.title.toLowerCase());
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({required this.group, required this.onTap});

  final WorkGroup group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return InkWell(
      onTap: onTap,
      hoverColor: tokens.hover,
      child: Container(
        height: tokens.density.rowHeight,
        padding: const EdgeInsets.symmetric(horizontal: FundusSpace.x6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.divider)),
        ),
        child: Row(
          children: [
            Icon(
              FundusIcons.folder,
              size: FundusIcons.sizeMd,
              color: tokens.textFaint,
            ),
            const SizedBox(width: FundusSpace.x3),
            Expanded(
              // Ein Ordnerpfad wird gelesen, nicht ausgesprochen: die
              // Trennzeichen stehen so, wie man sie im Finder sieht.
              child: Text(
                group.label.replaceAll('/', ' › '),
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Text(
              '${group.count} Werke',
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceSectionHeader extends StatelessWidget {
  const _SourceSectionHeader({required this.name, required this.count});

  final String name;
  final int count;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FundusSpace.x6,
        FundusSpace.x6,
        FundusSpace.x6,
        FundusSpace.x1,
      ),
      child: Row(
        children: [
          Icon(
            FundusIcons.lists,
            size: FundusIcons.sizeSm,
            color: tokens.accent,
          ),
          const SizedBox(width: FundusSpace.x2),
          Expanded(
            child: Text(
              name,
              style: theme.textTheme.titleSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '$count Werke',
            style: theme.textTheme.labelMedium?.copyWith(
              color: tokens.textFaint,
            ),
          ),
        ],
      ),
    );
  }
}

/// The saved views, as chips over the shelf.
///
/// „Shōnen", „offline", „laufend" — the handful of ways somebody actually
/// looks at their own library, one tap away and combinable. Several at once
/// read as „and also". They live in the vault, so the phone has the same
/// ones.
/// Was mit den ausgewählten Werken geschehen kann.
///
/// Mehrere Werke auf einmal zu pflegen ist der Normalfall, sobald eine Reihe
/// im Spiel ist: zwölf Bände eines Hörbuchs haben denselben Autor, denselben
/// Verlag und dieselbe Reihe, und die einzeln einzutragen ist Arbeit ohne
/// Erkenntnis.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.works,
    required this.onClear,
    required this.onSelectAll,
  });

  final List<WorkView> works;
  final VoidCallback onClear;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final theme = Theme.of(context);
    final writable = scope.library.library?.isReadOnly == false;

    return Container(
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(top: BorderSide(color: tokens.divider)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: FundusSpace.x4,
        vertical: FundusSpace.x3,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Text(
              '${works.length} ausgewählt',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(width: FundusSpace.x4),
            TextButton(onPressed: onSelectAll, child: const Text('Alle')),
            const SizedBox(width: FundusSpace.x2),
            TextButton(onPressed: onClear, child: const Text('Aufheben')),
            const SizedBox(width: FundusSpace.x4),
            FilledButton.icon(
              onPressed: !writable || works.isEmpty
                  ? null
                  : () => unawaited(_edit(context, scope)),
              icon: Icon(FundusIcons.edit, size: FundusIcons.sizeSm),
              label: const Text('Gemeinsam bearbeiten'),
            ),
            const SizedBox(width: FundusSpace.x2),
            OutlinedButton.icon(
              onPressed: !writable || works.isEmpty
                  ? null
                  : () => unawaited(_match(context, scope)),
              icon: Icon(FundusIcons.search, size: FundusIcons.sizeSm),
              label: const Text('Details abgleichen'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, FundusScopeState scope) async {
    final vault = scope.library.library;
    if (vault == null) return;
    final changed = await showBatchEditor(
      context,
      library: vault,
      works: works,
    );
    if (changed) scope.library.refresh();
  }

  Future<void> _match(BuildContext context, FundusScopeState scope) async {
    final vault = scope.library.library;
    if (vault == null) return;
    await showBulkMetadata(
      context,
      works: works,
      library: vault,
      settings: scope.settings,
      onChanged: scope.library.refresh,
      mediaTypeId: works.first.mediaType?.id,
    );
  }
}

/// Die Leiste über jedem Regal: filtern, ordnen, merken.
///
/// Sie steht hier und nicht in der Kopfzeile, weil sie zum Regal gehört —
/// und weil eine Kopfzeile auf dem Handy keinen Platz dafür hat. Genau das
/// fehlte dort bisher, obwohl „was liegt offline hier?" unterwegs die
/// häufigste Frage ist.
class _ShelfBar extends StatelessWidget {
  const _ShelfBar({required this.works});

  /// Alle Werke des Tresors — daraus kommen die Genres, die zur Auswahl
  /// stehen. Gefiltert wird danach, nicht aus einer festen Liste: eine
  /// Bibliothek weiß selbst am besten, was in ihr steht.
  final List<WorkView> works;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final filter = scope.filter;
    final views = scope.savedViews;
    final canSave = scope.library.library?.isReadOnly == false;

    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: FundusSpace.x6),
        children: [
          _OriginChip(filter: filter, onChanged: scope.setFilter),
          const SizedBox(width: FundusSpace.x2),
          _LabelChip(
            filter: filter,
            labels: _labels(works, filter),
            onChanged: scope.setFilter,
          ),
          const SizedBox(width: FundusSpace.x2),
          _SortChip(filter: filter, onChanged: scope.setFilter),
          const SizedBox(width: FundusSpace.x2),
          FilterChip(
            selected: filter.favouritesOnly,
            onSelected: (on) =>
                scope.setFilter(filter.copyWith(favouritesOnly: on)),
            avatar: Icon(
              filter.favouritesOnly
                  ? FundusIcons.favourite
                  : FundusIcons.favourites,
              size: FundusIcons.sizeSm,
            ),
            label: const Text('Favoriten'),
          ),
          // Die gewählten Genres stehen als eigene Chips daneben: sie sind
          // das, was gerade gilt, und ein Tipp nimmt sie wieder weg.
          for (final label in filter.tags) ...[
            const SizedBox(width: FundusSpace.x2),
            InputChip(
              selected: true,
              label: Text(label),
              onSelected: (_) => scope.setFilter(
                filter.copyWith(tags: {...filter.tags}..remove(label)),
              ),
              onDeleted: () => scope.setFilter(
                filter.copyWith(tags: {...filter.tags}..remove(label)),
              ),
              deleteIcon: Icon(FundusIcons.close, size: FundusIcons.sizeSm),
            ),
          ],
          if (views.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: FundusSpace.x3,
                vertical: FundusSpace.x2,
              ),
              child: VerticalDivider(width: 1, color: tokens.divider),
            ),
          for (final view in views) ...[
            FilterChip(
              selected: scope.activeViews.contains(view.id),
              onSelected: (_) => scope.toggleSavedView(view),
              label: Text(view.name),
              onDeleted: canSave
                  ? () => unawaited(scope.deleteSavedView(view.id))
                  : null,
              deleteIcon: Icon(
                FundusIcons.close,
                size: FundusIcons.sizeSm,
                color: tokens.textFaint,
              ),
            ),
            const SizedBox(width: FundusSpace.x2),
          ],
          // Was gerade auf dem Schirm steht, lässt sich behalten — das ist
          // der Weg, auf dem diese Reihe überhaupt entsteht.
          if (canSave && filter.hasActiveFilters)
            ActionChip(
              avatar: Icon(FundusIcons.add, size: FundusIcons.sizeSm),
              label: const Text('Diese Ansicht merken'),
              onPressed: () => unawaited(_save(context, scope)),
            ),
          if (filter.hasActiveFilters) ...[
            const SizedBox(width: FundusSpace.x2),
            ActionChip(
              label: const Text('Zurücksetzen'),
              onPressed: () => scope.setFilter(
                WorkFilter(
                  mediaTypeId: filter.mediaTypeId,
                  sort: filter.sort,
                  grouping: filter.grouping,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Die Genres und Schlagworte, die in diesem Regal wirklich vorkommen,
  /// die häufigsten zuerst.
  ///
  /// Eine feste Liste wäre geraten; eine Bibliothek weiß selbst, was in ihr
  /// steht — und nur was vorkommt, kann auch etwas finden.
  static List<String> _labels(List<WorkView> works, WorkFilter filter) {
    final counts = <String, int>{};
    for (final work in works) {
      if (filter.mediaTypeId != null &&
          work.mediaType?.id != filter.mediaTypeId) {
        continue;
      }
      for (final label in WorkFilter.labelsOf(work)) {
        final clean = label.trim();
        if (clean.isEmpty) continue;
        counts[clean] = (counts[clean] ?? 0) + 1;
      }
    }
    final labels = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0
            ? byCount
            : a.toLowerCase().compareTo(b.toLowerCase());
      });
    return labels.take(60).toList(growable: false);
  }

  Future<void> _save(BuildContext context, FundusScopeState scope) async {
    final name = await askForListName(context, title: 'Ansicht merken');
    if (name == null) return;
    await scope.saveCurrentView(name);
  }
}

/// „Wo liegt es?" — lokal, gestreamt, offline mitgenommen, nicht erreichbar.
class _OriginChip extends StatelessWidget {
  const _OriginChip({required this.filter, required this.onChanged});

  final WorkFilter filter;
  final void Function(WorkFilter) onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return PopupMenuButton<FundusOrigin>(
      tooltip: 'Nach Herkunft filtern',
      position: PopupMenuPosition.under,
      color: tokens.surface,
      onSelected: (origin) {
        final origins = {...filter.origins};
        origins.contains(origin) ? origins.remove(origin) : origins.add(origin);
        onChanged(filter.copyWith(origins: origins));
      },
      itemBuilder: (context) => [
        for (final origin in FundusOrigin.values)
          CheckedPopupMenuItem(
            value: origin,
            checked: filter.origins.contains(origin),
            child: FundusOriginMark(origin, showLabel: true),
          ),
      ],
      child: FilterChip(
        selected: filter.origins.isNotEmpty,
        onSelected: null,
        avatar: Icon(FundusIcons.filter, size: FundusIcons.sizeSm),
        label: Text(
          filter.origins.isEmpty
              ? 'Herkunft'
              : filter.origins.map((origin) => origin.label).join(', '),
        ),
      ),
    );
  }
}

/// Die Genres dieses Regals, zum Anhaken und Mischen.
class _LabelChip extends StatelessWidget {
  const _LabelChip({
    required this.filter,
    required this.labels,
    required this.onChanged,
  });

  final WorkFilter filter;
  final List<String> labels;
  final void Function(WorkFilter) onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    if (labels.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      tooltip: 'Nach Genre filtern',
      position: PopupMenuPosition.under,
      color: tokens.surface,
      constraints: const BoxConstraints(maxHeight: 420, minWidth: 220),
      onSelected: (label) {
        final tags = {...filter.tags};
        tags.contains(label) ? tags.remove(label) : tags.add(label);
        onChanged(filter.copyWith(tags: tags));
      },
      itemBuilder: (context) => [
        for (final label in labels)
          CheckedPopupMenuItem(
            value: label,
            checked: filter.tags.contains(label),
            child: Text(label),
          ),
      ],
      child: FilterChip(
        selected: filter.tags.isNotEmpty,
        onSelected: null,
        avatar: Icon(FundusIcons.filter, size: FundusIcons.sizeSm),
        label: const Text('Genre'),
      ),
    );
  }
}

/// Wonach sortiert wird.
class _SortChip extends StatelessWidget {
  const _SortChip({required this.filter, required this.onChanged});

  final WorkFilter filter;
  final void Function(WorkFilter) onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return PopupMenuButton<WorkSort>(
      tooltip: 'Sortierung',
      position: PopupMenuPosition.under,
      color: tokens.surface,
      onSelected: (sort) => onChanged(filter.copyWith(sort: sort)),
      itemBuilder: (context) => [
        for (final sort in WorkSort.values)
          CheckedPopupMenuItem(
            value: sort,
            checked: filter.sort == sort,
            child: Text(sort.label),
          ),
      ],
      child: FilterChip(
        selected: false,
        onSelected: null,
        avatar: Icon(FundusIcons.sort, size: FundusIcons.sizeSm),
        label: Text(filter.sort.label),
      ),
    );
  }
}

class _GroupingBar extends StatelessWidget {
  const _GroupingBar({
    required this.title,
    required this.count,
    required this.groupings,
    required this.selected,
    required this.onSelect,
    this.onMatchAll,
  });

  /// Null, wo die Pfadleiste oben den Namen schon trägt.
  final String? title;
  final int? count;
  final List<GroupingMode> groupings;
  final GroupingMode selected;
  final void Function(GroupingMode) onSelect;

  /// Null where there is nothing to match — an empty view, a mirrored vault.
  final VoidCallback? onMatchAll;

  /// Below this the heading and the sorting control no longer fit on one
  /// line — a phone, or a narrow window on a desktop.
  static const _stackBelow = 560.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;

    final heading = [
      if (title case final name?) ...[
        Flexible(
          child: Text(
            name,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineMedium,
          ),
        ),
        const SizedBox(width: FundusSpace.x3),
      ],
      if (count case final many?)
        Text(
          '$many',
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.textFaint),
        ),
    ];

    final sorting = [
      if (onMatchAll != null) ...[
        IconButton(
          onPressed: onMatchAll,
          icon: Icon(FundusIcons.search, size: FundusIcons.sizeMd),
          tooltip: 'Details für diese Ansicht holen',
        ),
        const SizedBox(width: FundusSpace.x2),
      ],
      Text(
        'Ordnen nach',
        style: theme.textTheme.labelMedium?.copyWith(color: tokens.textFaint),
      ),
      const SizedBox(width: FundusSpace.x3),
      _Segmented(groupings: groupings, selected: selected, onSelect: onSelect),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FundusSpace.x6,
        FundusSpace.x6,
        FundusSpace.x6,
        FundusSpace.x3,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (heading.isEmpty) {
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: sorting),
            );
          }
          if (constraints.maxWidth >= _stackBelow) {
            return Row(children: [...heading, const Spacer(), ...sorting]);
          }
          // Two lines rather than a squeezed one, and the modes scroll if
          // there are more of them than the screen is wide.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: heading),
              const SizedBox(height: FundusSpace.x3),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: sorting),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.groupings,
    required this.selected,
    required this.onSelect,
  });

  final List<GroupingMode> groupings;
  final GroupingMode selected;
  final void Function(GroupingMode) onSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Container(
      decoration: BoxDecoration(
        borderRadius: FundusRadius.mdAll,
        border: Border.fromBorderSide(BorderSide(color: tokens.divider)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final mode in groupings)
            InkWell(
              onTap: () => onSelect(mode),
              borderRadius: FundusRadius.mdAll,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: FundusSpace.x3,
                  vertical: FundusSpace.x2,
                ),
                decoration: BoxDecoration(
                  color: mode == selected ? tokens.surfaceRaised : null,
                  borderRadius: FundusRadius.mdAll,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      mode.icon,
                      size: FundusIcons.sizeSm,
                      color: mode == selected
                          ? tokens.accentRamp.s200
                          : tokens.textFaint,
                    ),
                    const SizedBox(width: FundusSpace.x2),
                    Text(
                      mode.label,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: mode == selected
                            ? tokens.accentRamp.s200
                            : tokens.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
