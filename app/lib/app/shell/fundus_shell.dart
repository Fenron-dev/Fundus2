import 'package:flutter/material.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../features/dashboard/dashboard_screen.dart';
import '../../features/downloads/downloads_screen.dart';
import '../../features/library/library_screen.dart';
import '../../features/player/player_bar.dart';
import '../../features/player/player_screen.dart';
import '../../features/reader/reader_screen.dart';
import '../../features/photos/photo_screen.dart';
import '../../features/reader/text_reader_screen.dart';
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
    // A reader or a full player owns its gestures. An edge swipe there means
    // turn the page, not open the navigation.
    final overlaid =
        scope.player.isExpanded ||
        scope.reader.isOpen ||
        scope.textReader.isOpen ||
        scope.photos.isOpen;
    return Scaffold(
      drawer: isCompact ? const _NavigationDrawer() : null,
      drawerEnableOpenDragGesture: isCompact && !overlaid,
      body: Stack(
        // The stack takes its size from the window, not from its children: the
        // shell below is the only child with a size of its own, and an
        // offstage child has none, which would leave the reader above it
        // filling nothing.
        fit: StackFit.expand,
        children: [
          // Taken out of the picture while something covers it, and kept
          // alive underneath.
          //
          // A stack paints every layer: the library grid, its covers and the
          // navigation column were being laid out and drawn behind each frame
          // of a playing film, for a window nobody could see. That is most of
          // what „laggy" was. Offstage skips layout and paint — and with it
          // the building of every lazy list's children — while the elements
          // stay, so scroll positions and open panels are where they were on
          // the way back.
          Offstage(
            offstage: overlaid,
            child: TickerMode(
              enabled: !overlaid,
              child: SafeArea(
                child: isCompact ? const _CompactShell() : const _WideShell(),
              ),
            ),
          ),
          // The full player covers the shell instead of pushing it aside; it
          // is one screen more, not a second navigation.
          if (scope.player.isExpanded)
            const Positioned.fill(child: PlayerScreen()),
          // The reader covers the shell the same way; a page wants the whole
          // window, not a column beside the navigation.
          if (scope.reader.isOpen) const Positioned.fill(child: ReaderScreen()),
          if (scope.textReader.isOpen)
            const Positioned.fill(child: TextReaderScreen()),
          // An album covers the shell the same way a reader does: pictures
          // want the window, not a column beside the navigation.
          if (scope.photos.isOpen) const Positioned.fill(child: PhotoScreen()),
        ],
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
              const PlayerBar(),
            ],
          ),
        ),
      ],
    );
  }
}

/// The navigation column, pulled in from the edge.
///
/// Same column, same entries — a phone has no room to keep it standing, so it
/// waits at the left edge instead of becoming a second, smaller navigation.
class _NavigationDrawer extends StatelessWidget {
  const _NavigationDrawer();

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Drawer(
      width: FundusShellMetrics.navigationWidth + FundusSpace.x12,
      backgroundColor: tokens.background,
      shape: const RoundedRectangleBorder(),
      child: SafeArea(
        child: NavigationPane(
          collapsed: false,
          width: double.infinity,
          onNavigate: () => Navigator.of(context).maybePop(),
        ),
      ),
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
        const CompactPlayerBar(),
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
          IconButton(
            onPressed: Scaffold.of(context).openDrawer,
            icon: Icon(FundusIcons.sidebar, size: FundusIcons.sizeMd),
            tooltip: 'Navigation',
          ),
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
          if (scope.peerLibraries.hasConnection)
            Padding(
              padding: const EdgeInsets.only(right: FundusSpace.x2),
              child: FundusConnectionDot(
                state: scope.peerLibraries.connection,
                showLabel: false,
                label: connectionLabel(scope),
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

/// What the mark means, named by machine.
///
/// „Zwei von drei Geräten antworten" is what a person can act on; a green dot
/// on its own only says that something, somewhere, is fine.
String connectionLabel(FundusScopeState scope) {
  final all = scope.peerLibraries.connected;
  final answering = all
      .where((entry) => entry.connection == FundusConnectionState.connected)
      .map((entry) => entry.peer.name)
      .toList();
  if (answering.isEmpty) {
    return all.length == 1
        ? '„${all.single.peer.name}" antwortet gerade nicht'
        : 'Kein gekoppeltes Gerät antwortet';
  }
  if (answering.length == all.length) {
    return answering.length == 1
        ? '„${answering.single}" antwortet'
        : 'Alle gekoppelten Geräte antworten';
  }
  return '${answering.join(', ')} antwortet — ${all.length - answering.length} nicht';
}
