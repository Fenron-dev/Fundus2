import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../data/media_type.dart';
import '../app_navigation.dart';
import '../../features/settings/settings_catalog.dart';
import '../fundus_scope.dart';

/// One entry in the navigation column.
@immutable
final class NavigationEntry {
  const NavigationEntry({
    required this.label,
    required this.icon,
    required this.onTap,
    this.count,
    this.active = false,
    this.ruleAfter = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final String? count;
  final bool active;

  /// A hairline below this entry — the design groups by rules, not headings.
  final bool ruleAfter;
}

/// The left column: place first, everything else below it.
///
/// There is never a second sidebar. Sub-areas such as the settings take this
/// same column over, keeping the vault switch at the top and downloads,
/// settings and the device at the bottom.
class NavigationPane extends StatefulWidget {
  const NavigationPane({
    super.key,
    required this.collapsed,
    this.width,
    this.onNavigate,
  });

  final bool collapsed;

  /// Overrides the column width. A drawer hands it its own.
  final double? width;

  /// Called after any entry was tapped. A drawer closes itself with it; the
  /// permanent column has nothing to do.
  final VoidCallback? onNavigate;

  @override
  State<NavigationPane> createState() => _NavigationPaneState();
}

class _NavigationPaneState extends State<NavigationPane> {
  final Set<String> _expandedSources = <String>{};

  bool get collapsed => widget.collapsed;
  VoidCallback? get onNavigate => widget.onNavigate;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final route = scope.navigation.current;
    final inSettings = route is SettingsRoute;

    return Container(
      width:
          widget.width ??
          (collapsed
              ? FundusShellMetrics.navigationCollapsedWidth
              : FundusShellMetrics.navigationWidth),
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: tokens.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _VaultButton(collapsed: collapsed),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: FundusSpace.x3,
                vertical: FundusSpace.x2,
              ),
              children: inSettings
                  ? _settingsEntries(context, scope)
                  : _mediaEntries(context, scope),
            ),
          ),
          Divider(height: 1, color: tokens.divider),
          ..._footerEntries(context, scope).map(
            (entry) => _NavigationTile(
              entry: entry,
              collapsed: collapsed,
              onNavigate: onNavigate,
            ),
          ),
          _DeviceRow(collapsed: collapsed),
        ],
      ),
    );
  }

  List<Widget> _mediaEntries(BuildContext context, FundusScopeState scope) {
    final route = scope.navigation.current;
    final activeType = route is LibraryRoute ? route.mediaTypeId : null;
    final counts = scope.library.worksPerMediaType;
    final unassigned = scope.library.unassignedWorkCount;
    final favourites = scope.library.works
        .where((work) => work.summary.favourite)
        .length;
    final rootEntries = _configuredRootEntries(scope);

    final entries = <NavigationEntry>[
      NavigationEntry(
        label: 'Dashboard',
        icon: FundusIcons.dashboard,
        active: route is DashboardRoute,
        onTap: () => scope.navigation.go(const DashboardRoute()),
      ),
      NavigationEntry(
        label: 'Alle Werke',
        icon: FundusIcons.lists,
        count: _formatCount(scope.library.works.length),
        active: route is LibraryRoute && activeType == null,
        ruleAfter: true,
        onTap: () => scope.openMediaType(null),
      ),
      if (favourites > 0)
        NavigationEntry(
          label: 'Favoriten',
          icon: FundusIcons.favourite,
          count: _formatCount(favourites),
          active: route is LibraryRoute && scope.filter.favouritesOnly,
          ruleAfter: true,
          onTap: () {
            scope.setFilter(
              scope.filter.copyWith(favouritesOnly: true, clearMediaType: true),
            );
            scope.navigation.go(const LibraryRoute());
          },
        ),
      // In der Reihenfolge, die der Nutzer gesetzt hat, und ohne Trennlinie
      // mitten in der Liste: was oben und was unten steht, entscheidet er.
      for (final type in MediaTypes.ordered(scope.settings.mediaTypeOrder))
        if ((counts[type.id] ?? 0) > 0 || !type.protected)
          NavigationEntry(
            label: type.label,
            icon: type.icon,
            count: _formatCount(counts[type.id] ?? 0),
            active: activeType == type.id,
            onTap: () => scope.openMediaType(type.id),
          ),
      for (final root in rootEntries)
        NavigationEntry(
          label: root.label,
          icon: root.type.icon,
          count: _formatCount(root.count),
          active: scope.filter.mediaRoot == root.path,
          onTap: () => scope.openMediaRoot(root.path, root.type.id),
        ),
      if (unassigned > 0)
        NavigationEntry(
          label: 'Nicht zugeordnet',
          icon: FundusIcons.warning,
          count: _formatCount(unassigned),
          active: false,
          onTap: () {
            scope.setFilter(
              scope.filter.copyWith(unassignedOnly: true, clearMediaType: true),
            );
            scope.navigation.go(const LibraryRoute());
          },
        ),
    ];

    return [
      for (final entry in entries)
        _NavigationTile(
          entry: entry,
          collapsed: collapsed,
          onNavigate: onNavigate,
        ),
      ..._sourceEntries(context, scope),
    ];
  }

  List<({String path, String label, MediaTypeDefinition type, int count})>
  _configuredRootEntries(FundusScopeState scope) {
    final library = scope.library.library;
    if (library == null) return const [];
    final selected = scope.settings.navigationMediaRoots;
    final entries =
        <({String path, String label, MediaTypeDefinition type, int count})>[];
    for (final type in MediaTypes.all) {
      final kind = type.configurationKind;
      if (kind == null) continue;
      final sensitive = library.configuration.sensitiveRootsFor(kind).toSet();
      for (final root in library.configuration.rootsFor(kind)) {
        if (!selected.contains(root)) continue;
        if (sensitive.contains(root) && !scope.protection.isUnlocked) continue;
        final normalized = root.replaceAll('\\', '/').toLowerCase();
        final count = scope.library.works.where((work) {
          final path = work.summary.sourcePath
              .replaceAll('\\', '/')
              .toLowerCase();
          return path == normalized || path.startsWith('$normalized/');
        }).length;
        if (count == 0) continue;
        entries.add((
          path: root,
          label: root.split(RegExp(r'[/\\]')).last,
          type: type,
          count: count,
        ));
      }
    }
    entries.sort((left, right) => left.label.compareTo(right.label));
    return entries;
  }

  List<Widget> _settingsEntries(BuildContext context, FundusScopeState scope) {
    final route = scope.navigation.current as SettingsRoute;

    return [
      _NavigationTile(
        collapsed: collapsed,
        onNavigate: onNavigate,
        entry: NavigationEntry(
          label: 'Zurück zum Dashboard',
          icon: FundusIcons.back,
          onTap: () => scope.navigation.go(const DashboardRoute()),
          ruleAfter: true,
        ),
      ),
      for (final area in SettingsAreas.all)
        _NavigationTile(
          collapsed: collapsed,
          onNavigate: onNavigate,
          entry: NavigationEntry(
            label: area.label,
            icon: area.icon,
            active: route.category == area.key,
            onTap: () => scope.navigation.go(SettingsRoute(category: area.key)),
          ),
        ),
    ];
  }

  /// The machines whose libraries run together in this vault.
  ///
  /// Only when there is more than one shelf to separate: a vault that is its
  /// own only source has nothing to filter by, and a list with one entry
  /// called „dieses Gerät" is a line of furniture.
  List<Widget> _sourceEntries(BuildContext context, FundusScopeState scope) {
    final mirrored = scope.library.sources
        .where(
          (source) =>
              !source.isVault &&
              !scope.settings.hiddenSourceIds.contains(source.id),
        )
        .toList();
    if (mirrored.isEmpty) return const [];

    final counts = scope.library.worksPerSource;
    final route = scope.navigation.current;
    final active = route is LibraryRoute ? scope.filter.sourceId : null;
    final activeType = route is LibraryRoute ? route.mediaTypeId : null;

    return [
      _NavigationTile(
        collapsed: collapsed,
        onNavigate: onNavigate,
        entry: NavigationEntry(
          label: 'GERÄTE',
          icon: FundusIcons.devices,
          onTap: () {},
        ),
      ),
      for (final source in [
        ...scope.library.sources.where(
          (source) =>
              source.isVault &&
              !scope.settings.hiddenSourceIds.contains(source.id),
        ),
        ...mirrored,
      ])
        _SourceNavigationGroup(
          source: source,
          collapsed: collapsed,
          expanded: _expandedSources.contains(source.id),
          count: _formatCount(counts[source.id] ?? 0),
          active: active == source.id,
          onToggle: () => setState(() {
            if (!_expandedSources.add(source.id)) {
              _expandedSources.remove(source.id);
            }
          }),
          onNavigate: onNavigate,
          onSelect: () =>
              scope.showSource(active == source.id ? null : source.id),
          typeEntries: [
            for (final type in MediaTypes.ordered(
              scope.settings.mediaTypeOrder,
            ))
              if (scope.library.worksPerSourceMediaType[source.id]?[type.id] !=
                      null &&
                  scope.library.worksPerSourceMediaType[source.id]![type.id]! >
                      0)
                _NavigationTile(
                  collapsed: false,
                  onNavigate: onNavigate,
                  entry: NavigationEntry(
                    label: type.label,
                    icon: type.icon,
                    count: _formatCount(
                      scope.library.worksPerSourceMediaType[source.id]![type
                          .id]!,
                    ),
                    active: active == source.id && activeType == type.id,
                    onTap: () => scope.showSourceMediaType(source.id, type.id),
                  ),
                ),
          ],
        ),
    ];
  }

  List<NavigationEntry> _footerEntries(
    BuildContext context,
    FundusScopeState scope,
  ) => [
    NavigationEntry(
      label: 'Listen',
      icon: FundusIcons.lists,
      active:
          scope.navigation.current is ListsRoute ||
          scope.navigation.current is ListRoute,
      onTap: () => scope.navigation.go(const ListsRoute()),
    ),
    NavigationEntry(
      label: 'Downloads',
      icon: FundusIcons.downloads,
      active: scope.navigation.current is DownloadsRoute,
      onTap: () => scope.navigation.go(const DownloadsRoute()),
    ),
    NavigationEntry(
      label: 'Einstellungen',
      icon: FundusIcons.settings,
      active: scope.navigation.current is SettingsRoute,
      onTap: () => scope.navigation.go(const SettingsRoute()),
    ),
  ];

  static String _formatCount(int value) {
    if (value < 1000) return '$value';
    final text = '$value';
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (i > 0 && (text.length - i) % 3 == 0) buffer.write(' ');
      buffer.write(text[i]);
    }
    return buffer.toString();
  }
}

class _SourceNavigationGroup extends StatelessWidget {
  const _SourceNavigationGroup({
    required this.source,
    required this.collapsed,
    required this.expanded,
    required this.count,
    required this.active,
    required this.onToggle,
    required this.onNavigate,
    required this.onSelect,
    required this.typeEntries,
  });

  final LibrarySource source;
  final bool collapsed;
  final bool expanded;
  final String count;
  final bool active;
  final VoidCallback onToggle;
  final VoidCallback? onNavigate;
  final VoidCallback onSelect;
  final List<Widget> typeEntries;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final icon = source.isVault
        ? FundusIcons.originLocal
        : switch (source.status) {
            LibrarySourceStatus.available => FundusIcons.originStream,
            _ => FundusIcons.originUnreachable,
          };
    final tile = InkWell(
      onTap: collapsed ? onSelect : onToggle,
      borderRadius: FundusRadius.mdAll,
      hoverColor: tokens.hover,
      child: Container(
        height: 32,
        padding: EdgeInsets.symmetric(
          horizontal: collapsed ? 0 : FundusSpace.x3,
        ),
        decoration: BoxDecoration(
          color: active ? tokens.surfaceRaised : null,
          borderRadius: FundusRadius.mdAll,
        ),
        child: Row(
          mainAxisAlignment: collapsed
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            Icon(icon, size: FundusIcons.sizeMd, color: tokens.textMuted),
            if (!collapsed) ...[
              const SizedBox(width: FundusSpace.x3),
              Expanded(
                child: Text(
                  source.isVault ? 'Auf diesem Gerät' : source.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              Text(
                count,
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
              ),
              const SizedBox(width: FundusSpace.x1),
              Icon(
                expanded ? FundusIcons.expand : FundusIcons.collapse,
                size: FundusIcons.sizeSm,
                color: tokens.textFaint,
              ),
            ],
          ],
        ),
      ),
    );
    final body = <Widget>[
      Padding(
        padding: EdgeInsets.only(
          left: collapsed ? FundusSpace.x2 : 0,
          right: collapsed ? FundusSpace.x2 : 0,
          bottom: 1,
        ),
        child: collapsed
            ? Tooltip(message: source.displayName, child: tile)
            : tile,
      ),
      if (!collapsed && expanded) ...typeEntries,
    ];
    return Column(children: body);
  }
}

class _NavigationTile extends StatelessWidget {
  const _NavigationTile({
    required this.entry,
    required this.collapsed,
    this.onNavigate,
  });

  final NavigationEntry entry;
  final bool collapsed;
  final VoidCallback? onNavigate;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final foreground = entry.active ? tokens.accentRamp.s200 : tokens.textMuted;

    final tile = InkWell(
      onTap: () {
        entry.onTap();
        onNavigate?.call();
      },
      borderRadius: FundusRadius.mdAll,
      hoverColor: tokens.hover,
      child: Container(
        height: 32,
        padding: EdgeInsets.symmetric(
          horizontal: collapsed ? 0 : FundusSpace.x3,
        ),
        decoration: BoxDecoration(
          color: entry.active ? tokens.surfaceRaised : null,
          borderRadius: FundusRadius.mdAll,
        ),
        child: Row(
          mainAxisAlignment: collapsed
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            Icon(entry.icon, size: FundusIcons.sizeMd, color: foreground),
            if (!collapsed) ...[
              const SizedBox(width: FundusSpace.x3),
              Expanded(
                child: Text(
                  entry.label,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: foreground),
                ),
              ),
              if (entry.count != null)
                Text(
                  entry.count!,
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
                ),
            ],
          ],
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(
        left: collapsed ? FundusSpace.x2 : 0,
        right: collapsed ? FundusSpace.x2 : 0,
        bottom: entry.ruleAfter ? 0 : 1,
      ),
      child: Column(
        children: [
          collapsed ? Tooltip(message: entry.label, child: tile) : tile,
          if (entry.ruleAfter)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: FundusSpace.x2),
              child: Divider(height: 1, color: tokens.divider),
            ),
        ],
      ),
    );
  }
}

class _VaultButton extends StatelessWidget {
  const _VaultButton({required this.collapsed});

  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;

    return InkWell(
      onTap: () => scope.navigation.go(const VaultRoute()),
      hoverColor: tokens.hover,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: collapsed ? FundusSpace.x2 : FundusSpace.x4,
          vertical: FundusSpace.x4,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.divider)),
        ),
        child: Row(
          mainAxisAlignment: collapsed
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: tokens.accentTint(0.16),
                borderRadius: FundusRadius.mdAll,
              ),
              child: Icon(
                FundusIcons.vault,
                size: FundusIcons.sizeSm,
                color: tokens.accent,
              ),
            ),
            if (!collapsed) ...[
              const SizedBox(width: FundusSpace.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      scope.library.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      scope.library.locationLabel,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: tokens.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                FundusIcons.vaultSwitch,
                size: FundusIcons.sizeSm,
                color: tokens.textFaint,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.collapsed});

  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.all(FundusSpace.x3),
        child: Tooltip(
          message: scope.settings.deviceName,
          child: Icon(
            FundusIcons.devices,
            size: FundusIcons.sizeMd,
            color: tokens.textFaint,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FundusSpace.x4,
        vertical: FundusSpace.x3,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  scope.settings.deviceName,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
                ),
                Text(
                  scope.library.isOpen
                      ? 'Bibliothek geöffnet'
                      : 'Keine Bibliothek',
                  style: Theme.of(
                    context,
                  ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
                ),
              ],
            ),
          ),
          Icon(
            FundusIcons.sync,
            size: FundusIcons.sizeSm,
            color: tokens.textFaint,
          ),
        ],
      ),
    );
  }
}
