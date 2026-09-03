import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/media_type.dart';
import '../../data/work_filter.dart';
import '../../data/work_view.dart';
import 'work_tile.dart';

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
        ),
        Expanded(
          child: works.isEmpty
              ? _empty(context, scope)
              : _body(context, scope, works, grouping),
        ),
      ],
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
  ) {
    void open(WorkView work) => scope.navigation.go(WorkRoute(work.id));

    if (grouping == GroupingMode.tiles) {
      return _TileGrid(works: works, onOpen: open);
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
      return _TileGrid(works: group?.works ?? const [], onOpen: open);
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
}

class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.works, required this.onOpen});

  final List<WorkView> works;
  final void Function(WorkView) onOpen;

  @override
  Widget build(BuildContext context) {
    final density = context.fundus.density;
    const padding = EdgeInsets.all(FundusSpace.x6);

    return LayoutBuilder(
      builder: (context, constraints) {
        // The same arithmetic the delegate below uses, so the height can be
        // worked out for the width a tile will actually get.
        final available = constraints.maxWidth - padding.horizontal;
        final columns = (available / density.tileMinWidth).ceil().clamp(1, 12);
        final tileWidth = (available - density.gap * (columns - 1)) / columns;

        // A grid of thousands of tiles has to be virtualised;
        // GridView.builder only builds what is on screen.
        return GridView.builder(
          padding: padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: density.gap,
            crossAxisSpacing: density.gap,
            mainAxisExtent: workTileExtent(
              tileWidth: tileWidth,
              density: density,
              textScaler: MediaQuery.textScalerOf(context),
            ),
          ),
          itemCount: works.length,
          itemBuilder: (context, index) =>
              WorkTile(work: works[index], onTap: () => onOpen(works[index])),
        );
      },
    );
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
              child: Text(
                group.label,
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

class _GroupingBar extends StatelessWidget {
  const _GroupingBar({
    required this.title,
    required this.count,
    required this.groupings,
    required this.selected,
    required this.onSelect,
  });

  final String title;
  final int count;
  final List<GroupingMode> groupings;
  final GroupingMode selected;
  final void Function(GroupingMode) onSelect;

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
