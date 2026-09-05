import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../data/media_type.dart';
import '../../data/work_filter.dart';
import '../app_navigation.dart';
import '../fundus_scope.dart';
import 'fundus_shell.dart';

/// One step of the path bar.
@immutable
final class PathStep {
  const PathStep(this.label, [this.onTap]);

  final String label;
  final VoidCallback? onTap;
}

/// The bar above the content column.
///
/// With the navigation collapsed the orientation moves in here as a full path —
/// on deep paths (Manga → Urheber → Reihe → Band) the way back matters more
/// than the list of areas.
class ShellHeader extends StatelessWidget {
  const ShellHeader({super.key, required this.onToggleNavigation});

  final VoidCallback onToggleNavigation;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final steps = pathSteps(scope);

    return Container(
      height: FundusShellMetrics.headerHeight,
      padding: const EdgeInsets.symmetric(horizontal: FundusSpace.x4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.divider)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: onToggleNavigation,
            icon: Icon(FundusIcons.sidebar, size: FundusIcons.sizeMd),
            tooltip: 'Seitenleiste ein- oder ausklappen',
          ),
          IconButton(
            onPressed: scope.navigation.canGoBack
                ? scope.navigation.back
                : null,
            icon: Icon(FundusIcons.back, size: FundusIcons.sizeMd),
            tooltip: 'Zurück',
          ),
          IconButton(
            onPressed: scope.navigation.canGoForward
                ? scope.navigation.forward
                : null,
            icon: Icon(FundusIcons.forward, size: FundusIcons.sizeMd),
            tooltip: 'Vor',
          ),
          const SizedBox(width: FundusSpace.x3),
          Expanded(child: _PathBar(steps: steps)),
          const SizedBox(width: FundusSpace.x3),
          // The search field gives way before the path does — on a narrow
          // window the way back matters more than a wide input.
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 120, maxWidth: 300),
              child: const _SearchField(),
            ),
          ),
          const SizedBox(width: FundusSpace.x3),
          const _ConnectionMark(),
          const _FilterButton(),
          const SizedBox(width: FundusSpace.x2),
          const _SortButton(),
        ],
      ),
    );
  }

  /// The path for the current route. Kept here rather than in each screen so
  /// every screen is reachable the same way.
  static List<PathStep> pathSteps(FundusScopeState scope) {
    final steps = <PathStep>[
      PathStep(scope.library.displayName, () {
        scope.navigation.go(const DashboardRoute());
      }),
    ];
    final route = scope.navigation.current;
    switch (route) {
      case LibraryRoute(:final mediaTypeId, :final group):
        final type = mediaTypeId == null ? null : MediaTypes.byId(mediaTypeId);
        steps.add(
          PathStep(type?.label ?? 'Alle Werke', () {
            scope.navigation.go(LibraryRoute(mediaTypeId: mediaTypeId));
          }),
        );
        if (group != null) steps.add(PathStep(group));
      case WorkRoute(:final workId):
        final work = scope.library.workById(workId);
        final type = work?.mediaType;
        if (type != null) {
          steps.add(PathStep(type.label, () => scope.openMediaType(type.id)));
        }
        if (work != null) steps.add(PathStep(work.title));
      case SettingsRoute():
        steps.add(const PathStep('Einstellungen'));
      case DownloadsRoute():
        steps.add(const PathStep('Downloads'));
      case SearchRoute():
        steps.add(const PathStep('Suche'));
      case DashboardRoute():
      case VaultRoute():
        break;
    }
    return steps;
  }
}

class _PathBar extends StatelessWidget {
  const _PathBar({required this.steps});

  final List<PathStep> steps;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final children = <Widget>[];
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final isLast = i == steps.length - 1;
      if (i > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: FundusSpace.x2),
            child: Text('›', style: TextStyle(color: tokens.textFaint)),
          ),
        );
      }
      final label = Text(
        step.label,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: isLast ? tokens.text : tokens.textMuted,
        ),
      );
      children.add(
        step.onTap == null
            ? Flexible(child: label)
            : Flexible(
                child: InkWell(
                  onTap: step.onTap,
                  borderRadius: FundusRadius.smAll,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FundusSpace.x1,
                    ),
                    child: label,
                  ),
                ),
              ),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}

class _SearchField extends StatefulWidget {
  const _SearchField();

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    // The filter can also be cleared from elsewhere — switching areas does it —
    // so the field follows it without stealing the caret while typing.
    if (_controller.text != scope.filter.text) {
      _controller.value = TextEditingValue(
        text: scope.filter.text,
        selection: TextSelection.collapsed(offset: scope.filter.text.length),
      );
    }
    return TextField(
      controller: _controller,
      onChanged: (value) => scope.setFilter(scope.filter.copyWith(text: value)),
      decoration: InputDecoration(
        hintText: 'Suchen in dieser Ansicht …',
        prefixIcon: Icon(FundusIcons.search, size: FundusIcons.sizeSm),
        prefixIconConstraints: const BoxConstraints(minWidth: 34),
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final count = scope.filter.activeFilterCount;

    return PopupMenuButton<FundusOrigin>(
      tooltip: 'Nach Herkunft filtern',
      position: PopupMenuPosition.under,
      color: tokens.surface,
      onSelected: (origin) {
        final origins = Set<FundusOrigin>.from(scope.filter.origins);
        origins.contains(origin) ? origins.remove(origin) : origins.add(origin);
        scope.setFilter(scope.filter.copyWith(origins: origins));
      },
      itemBuilder: (context) => [
        for (final origin in FundusOrigin.values)
          CheckedPopupMenuItem(
            value: origin,
            checked: scope.filter.origins.contains(origin),
            child: FundusOriginMark(origin, showLabel: true),
          ),
      ],
      child: _HeaderChip(
        icon: FundusIcons.filter,
        label: 'Filter',
        badge: count == 0 ? null : '$count',
      ),
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;

    return PopupMenuButton<WorkSort>(
      tooltip: 'Sortierung',
      position: PopupMenuPosition.under,
      color: tokens.surface,
      onSelected: (sort) => scope.setFilter(scope.filter.copyWith(sort: sort)),
      itemBuilder: (context) => [
        for (final sort in WorkSort.values)
          CheckedPopupMenuItem(
            value: sort,
            checked: scope.filter.sort == sort,
            child: Text(sort.label),
          ),
      ],
      child: _HeaderChip(
        icon: FundusIcons.sort,
        label: scope.filter.sort.label,
      ),
    );
  }
}

class _HeaderChip extends StatelessWidget {
  const _HeaderChip({required this.icon, required this.label, this.badge});

  final IconData icon;
  final String label;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: FundusSpace.x3),
      decoration: BoxDecoration(
        borderRadius: FundusRadius.mdAll,
        border: Border.fromBorderSide(BorderSide(color: tokens.divider)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: FundusIcons.sizeSm, color: tokens.textMuted),
          const SizedBox(width: FundusSpace.x2),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          if (badge != null) ...[
            const SizedBox(width: FundusSpace.x2),
            FundusTag(badge!, tone: FundusTagTone.accent),
          ],
        ],
      ),
    );
  }
}

/// Whether the other machine is on the line, where it can be seen at a glance.
///
/// It appears only when there is something to say: a library of one's own on a
/// machine that shares nothing has no connection to report, and a mark that is
/// always grey teaches people to stop looking at it.
class _ConnectionMark extends StatelessWidget {
  const _ConnectionMark();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final peers = scope.peerLibraries;
    final host = scope.host;

    // Reading someone else's library is the case where it matters most: what
    // is on screen depends on those machines answering.
    if (peers.hasConnection) {
      return Padding(
        padding: const EdgeInsets.only(right: FundusSpace.x3),
        child: FundusConnectionDot(
          state: peers.connection,
          showLabel: false,
          label: connectionLabel(scope),
        ),
      );
    }

    if (!host.isRunning) return const SizedBox.shrink();
    final connected = host.hasConnectedDevice;
    return Padding(
      padding: const EdgeInsets.only(right: FundusSpace.x3),
      child: FundusConnectionDot(
        state: connected
            ? FundusConnectionState.connected
            : FundusConnectionState.idle,
        showLabel: false,
        label: connected
            ? 'Ein gekoppeltes Gerät ist verbunden'
            : 'Freigegeben, gerade ist niemand verbunden',
      ),
    );
  }
}
