import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/media_type.dart';
import '../../data/work_filter.dart';
import '../../data/work_view.dart';
import '../work/bulk_metadata.dart';
import 'stage_screen.dart';
import 'work_grid.dart';
import 'work_row.dart';

/// The one library view.
///
/// It does not branch on where a work came from — origin is a column and a
/// filter. The "Ordnen nach" switch lays the same works out differently;
/// filters keep applying in every one of them, the folder view included.
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key, required this.route});

  final LibraryRoute route;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final type = route.mediaTypeId == null
        ? null
        : MediaTypes.byId(route.mediaTypeId!);
    final filter = scope.filter;
    final works = filter.apply(scope.library.works);

    final grouping = filter.grouping;
    final groupings =
        type?.groupings ??
        const [GroupingMode.tiles, GroupingMode.table, GroupingMode.folder];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GroupingBar(
          title: type?.label ?? 'Alle Werke',
          count: works.length,
          groupings: groupings,
          selected: grouping,
          onSelect: (mode) => scope.setFilter(filter.copyWith(grouping: mode)),
          onMatchAll: works.isEmpty
              ? null
              : () => unawaited(_matchAll(context, scope, works)),
        ),
        const _SavedViewBar(),
        Expanded(
          child: works.isEmpty
              ? _empty(context, scope)
              : _body(context, scope, works, grouping, type),
        ),
      ],
    );
  }

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
      if (StageScreen.suits(type) &&
          route.group == null &&
          scope.filter.text.isEmpty) {
        return StageScreen(works: works, type: type, onOpen: open);
      }
      return WorkGrid(works: works, onOpen: open);
    }
    if (grouping == GroupingMode.table) {
      return ListView.builder(
        itemCount: works.length,
        itemBuilder: (context, index) =>
            WorkRow(work: works[index], onTap: () => open(works[index])),
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

/// The saved views, as chips over the shelf.
///
/// „Shōnen", „offline", „laufend" — the handful of ways somebody actually
/// looks at their own library, one tap away and combinable. Several at once
/// read as „and also". They live in the vault, so the phone has the same
/// ones.
class _SavedViewBar extends StatelessWidget {
  const _SavedViewBar();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final views = scope.savedViews;
    final tokens = context.fundus;
    final canSave = scope.library.library?.isReadOnly == false;
    if (views.isEmpty && !scope.filter.hasActiveFilters) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: FundusSpace.x6),
        children: [
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
          if (canSave && scope.filter.hasActiveFilters)
            ActionChip(
              avatar: Icon(FundusIcons.add, size: FundusIcons.sizeSm),
              label: const Text('Diese Ansicht merken'),
              onPressed: () => unawaited(_save(context, scope)),
            ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context, FundusScopeState scope) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ansicht merken'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Merken'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    await scope.saveCurrentView(name);
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

  final String title;
  final int count;
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
      Flexible(
        child: Text(
          title,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineMedium,
        ),
      ),
      const SizedBox(width: FundusSpace.x3),
      Text(
        '$count',
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
