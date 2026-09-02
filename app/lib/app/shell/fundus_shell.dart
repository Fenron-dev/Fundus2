import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../features/dashboard/dashboard_screen.dart';
import '../../features/downloads/downloads_screen.dart';
import '../../features/library/library_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/vault/vault_screen.dart';
import '../../features/work/work_screen.dart';
import '../app_navigation.dart';
import '../fundus_scope.dart';
import 'navigation_pane.dart';
import 'shell_header.dart';

/// The application frame: one navigation column, one content column.
///
/// There is no permanent detail panel — a work detail is a screen of its own.
/// Below the mobile breakpoint the navigation column becomes a bottom bar; it
/// is the same navigation either way, not a second information architecture.
class FundusShell extends StatelessWidget {
  const FundusShell({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);

    if (scope.navigation.isVaultSelection || !scope.library.isOpen) {
      return const Scaffold(body: VaultScreen());
    }

    final isCompact =
        MediaQuery.sizeOf(context).width < FundusShellMetrics.compactBreakpoint;
    return Scaffold(
      body: SafeArea(
        child: isCompact ? const _CompactShell() : const _WideShell(),
      ),
    );
  }
}

class _WideShell extends StatelessWidget {
  const _WideShell();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    return Row(
      children: [
        NavigationPane(collapsed: scope.settings.navigationCollapsed),
        Expanded(
          child: Column(
            children: [
              ShellHeader(
                onToggleNavigation: () => scope.settings.setNavigationCollapsed(
                  !scope.settings.navigationCollapsed,
                ),
              ),
              const Expanded(child: ShellContent()),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompactShell extends StatelessWidget {
  const _CompactShell();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final route = scope.navigation.current;

    final destinations = <(String, IconData, FundusRoute)>[
      ('Start', FundusIcons.dashboard, const DashboardRoute()),
      ('Bibliothek', FundusIcons.lists, const LibraryRoute()),
      ('Downloads', FundusIcons.downloads, const DownloadsRoute()),
      ('Mehr', FundusIcons.settings, const SettingsRoute()),
    ];
    final selected = switch (route) {
      DashboardRoute() => 0,
      LibraryRoute() || WorkRoute() => 1,
      DownloadsRoute() => 2,
      _ => 3,
    };

    return Column(
      children: [
        _CompactHeader(),
        const Expanded(child: ShellContent()),
        Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: tokens.divider)),
          ),
          child: NavigationBar(
            height: 58,
            backgroundColor: tokens.background,
            indicatorColor: tokens.accentTint(0.16),
            selectedIndex: selected,
            onDestinationSelected: (index) {
              final target = destinations[index].$3;
              if (target is LibraryRoute) {
                scope.openMediaType(null);
              } else {
                scope.navigation.go(target);
              }
            },
            destinations: [
              for (final destination in destinations)
                NavigationDestination(
                  icon: Icon(destination.$2, size: FundusIcons.sizeMd),
                  label: destination.$1,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompactHeader extends StatelessWidget {
  const _CompactHeader();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final steps = ShellHeader.pathSteps(scope);

    return Container(
      height: FundusShellMetrics.headerHeight,
      padding: const EdgeInsets.symmetric(horizontal: FundusSpace.x3),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.divider)),
      ),
      child: Row(
        children: [
          if (scope.navigation.canGoBack)
            IconButton(
              onPressed: scope.navigation.back,
              icon: Icon(FundusIcons.back, size: FundusIcons.sizeMd),
              tooltip: 'Zurück',
            ),
          Expanded(
            child: Text(
              steps.last.label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            onPressed: () => scope.navigation.go(const VaultRoute()),
            icon: Icon(FundusIcons.vault, size: FundusIcons.sizeMd),
            tooltip: 'Bibliothek wechseln',
          ),
        ],
      ),
    );
  }
}

/// Draws the current route. Desktop and mobile share it — the screens adapt,
/// they are not duplicated.
class ShellContent extends StatelessWidget {
  const ShellContent({super.key});

  @override
  Widget build(BuildContext context) {
    final route = FundusScope.of(context).navigation.current;
    return switch (route) {
      VaultRoute() => const VaultScreen(),
      DashboardRoute() => const DashboardScreen(),
      LibraryRoute() => LibraryScreen(route: route),
      WorkRoute(:final workId) => WorkScreen(workId: workId),
      SettingsRoute(:final category) => SettingsScreen(category: category),
      DownloadsRoute() => const DownloadsScreen(),
      SearchRoute() => const LibraryScreen(route: LibraryRoute()),
    };
  }
}
