import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';
import '../../media/comic_layout.dart';
import '../../media/reader_controller.dart';

/// The page reader, laid over the shell.
///
/// Reading is the whole point, so the page gets the window and the chrome is
/// a guest: a tap in the middle sends it away and brings it back. Nothing in
/// here plays anything — a comic has pages, not a running time.
class ReaderScreen extends StatelessWidget {
  const ReaderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final reader = scope.reader;
    final work = reader.work;
    if (work == null) return const SizedBox.shrink();

    final tokens = context.fundus;

    return ColoredBox(
      color: tokens.background,
      child: SafeArea(
        top: reader.showsChrome,
        bottom: false,
        child: Column(
          children: [
            if (reader.showsChrome) const _ReaderBar(),
            const Expanded(child: _ReaderSurface()),
          ],
        ),
      ),
    );
  }
}

class _ReaderBar extends StatelessWidget {
  const _ReaderBar();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final reader = scope.reader;
    final work = reader.work!;
    final tokens = context.fundus;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FundusSpace.x4,
        vertical: FundusSpace.x2,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () {
              scope.fullscreen.leave();
              reader.close();
            },
            icon: Icon(FundusIcons.close, size: FundusIcons.sizeLg),
            tooltip: 'Schließen',
          ),
          const SizedBox(width: FundusSpace.x2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  work.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  reader.positionLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: tokens.textFaint,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: reader.addBookmark,
            icon: Icon(FundusIcons.bookmark, size: FundusIcons.sizeLg),
            tooltip: 'Lesezeichen setzen',
          ),
          if (reader.bookmarks.isNotEmpty)
            IconButton(
              onPressed: () => _showBookmarks(context),
              icon: Icon(FundusIcons.note, size: FundusIcons.sizeLg),
              tooltip: 'Lesezeichen',
            ),
          IconButton(
            onPressed: () => _savePage(context),
            icon: Icon(FundusIcons.camera, size: FundusIcons.sizeLg),
            tooltip: 'Seite speichern',
          ),
          IconButton(
            onPressed: () => _showPageOverview(context),
            icon: Icon(FundusIcons.viewGrid, size: FundusIcons.sizeLg),
            tooltip: 'Seitenvorschau',
          ),
          if (reader.volumes.length > 1) const _VolumeMenu(),
          IconButton(
            onPressed: () => _showReaderSettings(context),
            icon: Icon(FundusIcons.settings, size: FundusIcons.sizeLg),
            tooltip: 'Leseeinstellungen',
          ),
          IconButton(
            onPressed: scope.fullscreen.toggle,
            icon: Icon(FundusIcons.fullscreen, size: FundusIcons.sizeLg),
            tooltip: scope.fullscreen.isActive
                ? 'Vollbild beenden'
                : 'Vollbild',
          ),
        ],
      ),
    );
  }
}

class _VolumeMenu extends StatelessWidget {
  const _VolumeMenu();

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).reader;
    final sequence = reader.chapterSequence;
    return PopupMenuButton<int>(
      tooltip: 'Kapitel',
      icon: Icon(FundusIcons.manga, size: FundusIcons.sizeLg),
      onSelected: reader.openVolume,
      itemBuilder: (context) => [
        // Eine Lücke in der Nummerierung gehört genannt: sonst wundert man
        // sich nur, warum die Geschichte springt.
        if (sequence.summary case final warning?)
          PopupMenuItem(
            enabled: false,
            child: Row(
              children: [
                Icon(
                  FundusIcons.warning,
                  size: FundusIcons.sizeSm,
                  color: context.fundus.warning,
                ),
                const SizedBox(width: FundusSpace.x2),
                Flexible(
                  child: Text(
                    warning,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: context.fundus.warning,
                    ),
                  ),
                ),
              ],
            ),
          ),
        for (var index = 0; index < reader.volumes.length; index++)
          PopupMenuItem(
            value: index,
            child: Text(
              reader.volumes[index].title,
              style: index == reader.volumeIndex
                  ? TextStyle(color: context.fundus.accentRamp.s200)
                  : null,
            ),
          ),
      ],
    );
  }
}

/// The reading area: pages, tap zones and the keyboard.
class _ReaderSurface extends StatelessWidget {
  const _ReaderSurface();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final reader = scope.reader;
    final tokens = context.fundus;
    final failure = reader.failure;

    if (failure != null) {
      return Padding(
        padding: const EdgeInsets.all(FundusSpace.x10),
        child: FundusEmptyState(
          icon: FundusIcons.warning,
          title: 'Diese Datei lässt sich nicht öffnen',
          reason: failure,
        ),
      );
    }

    if (reader.pages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        // Right and left mean forward and back on the screen, which under a
        // right-to-left reading direction are the other way round.
        switch (event.logicalKey) {
          case LogicalKeyboardKey.arrowRight:
            reader.isRightToLeft ? reader.previousPage() : reader.nextPage();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowLeft:
            reader.isRightToLeft ? reader.nextPage() : reader.previousPage();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.space:
          case LogicalKeyboardKey.pageDown:
          case LogicalKeyboardKey.arrowDown:
            reader.nextPage();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.pageUp:
          case LogicalKeyboardKey.arrowUp:
            reader.previousPage();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.keyF:
            scope.fullscreen.toggle();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.escape:
            if (scope.fullscreen.isActive) {
              scope.fullscreen.leave();
            } else {
              reader.close();
            }
            return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ColoredBox(
        color: tokens.background,
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              Positioned.fill(
                child: reader.isContinuous
                    ? const _ContinuousPages()
                    : const _PagedPages(),
              ),
              // The tap zones sit over the page. Their width is the reader's
              // own setting, and a left-hander can swap them.
              ..._tapZones(reader, constraints.maxWidth),
              if (reader.isBusy)
                const Positioned(
                  top: FundusSpace.x4,
                  right: FundusSpace.x4,
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _tapZones(ReaderController reader, double width) {
    final edge = width * reader.profile.tapZoneWidth;
    // On the screen, left is back and right is forward — unless the work is
    // read right to left, or the zones were deliberately swapped.
    var leftGoesBack = !reader.isRightToLeft;
    if (reader.profile.invertTapZones) leftGoesBack = !leftGoesBack;
    return [
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: edge,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: leftGoesBack ? reader.previousPage : reader.nextPage,
        ),
      ),
      Positioned(
        left: edge,
        right: edge,
        top: 0,
        bottom: 0,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: reader.toggleChrome,
        ),
      ),
      Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        width: edge,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: leftGoesBack ? reader.nextPage : reader.previousPage,
        ),
      ),
    ];
  }
}

/// Single pages and spreads, turned one unit at a time.
class _PagedPages extends StatefulWidget {
  const _PagedPages();

  @override
  State<_PagedPages> createState() => _PagedPagesState();
}

class _PagedPagesState extends State<_PagedPages> {
  PageController? _controller;
  int _attachedTo = -1;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).reader;
    final groups = reader.pageGroups;
    if (groups.isEmpty) return const SizedBox.shrink();
    final unit = reader.groupIndex;

    _controller ??= PageController(initialPage: unit);
    // The controller follows jumps made elsewhere — a bookmark, the overview,
    // a chapter change — without fighting the user's own swipe.
    if (_attachedTo != unit) {
      _attachedTo = unit;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final controller = _controller;
        if (controller == null || !controller.hasClients) return;
        if (controller.page?.round() == unit) return;
        controller.jumpToPage(unit);
      });
    }

    return PageView.builder(
      controller: _controller,
      reverse: reader.isRightToLeft,
      itemCount: groups.length,
      onPageChanged: (index) {
        _attachedTo = index;
        reader.goToPage(groups[index].first);
      },
      itemBuilder: (context, index) {
        final group = groups[index];
        if (group.length == 1) {
          return _Page(index: group.single);
        }
        final pages = [
          for (final page in group) Expanded(child: _Page(index: page)),
        ];
        return Row(
          children: reader.isRightToLeft ? pages.reversed.toList() : pages,
        );
      },
    );
  }
}

/// Webtoon and the other continuous layouts: one strip, scrolled.
class _ContinuousPages extends StatefulWidget {
  const _ContinuousPages();

  @override
  State<_ContinuousPages> createState() => _ContinuousPagesState();
}

class _ContinuousPagesState extends State<_ContinuousPages> {
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  int _jumpedTo = -1;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_reportVisiblePage);
  }

  @override
  void dispose() {
    _scroll.removeListener(_reportVisiblePage);
    _scroll.dispose();
    super.dispose();
  }

  /// Which page is at the top of the viewport.
  ///
  /// Only the built items are measured, and a list only builds what is near
  /// the screen, so this stays a handful of comparisons rather than a walk
  /// through a two-hundred-page volume.
  void _reportVisiblePage() {
    if (!mounted) return;
    final reader = FundusScope.of(context).reader;
    final viewport = context.findRenderObject();
    if (viewport is! RenderBox) return;
    final horizontal =
        reader.profile.layout == PublicationReaderLayout.continuousHorizontal;

    int? best;
    var bestDistance = double.infinity;
    for (final entry in _keys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final offset = box.localToGlobal(Offset.zero, ancestor: viewport);
      final start = horizontal ? offset.dx : offset.dy;
      // The page that covers the top edge: the last one that starts above it.
      final distance = start <= 0 ? -start : start * 4;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = entry.key;
      }
    }
    if (best != null && best != reader.pageIndex) {
      reader.goToPage(best);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).reader;
    final horizontal =
        reader.profile.layout == PublicationReaderLayout.continuousHorizontal;

    // A jump from outside — bookmark, overview, chapter — has to move the
    // list; a scroll of the user's own must not be answered with one.
    if (_jumpedTo != reader.pageIndex) {
      final target = reader.pageIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _jumpedTo == target) return;
        final key = _keys[target];
        final box = key?.currentContext;
        if (box == null) return;
        _jumpedTo = target;
        Scrollable.ensureVisible(box, alignment: 0);
      });
    }

    return ListView.builder(
      controller: _scroll,
      scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
      reverse: horizontal && reader.isRightToLeft,
      itemCount: reader.pageCount,
      itemBuilder: (context, index) {
        reader.requestPage(index);
        final key = _keys.putIfAbsent(index, GlobalKey.new);
        return Padding(
          key: key,
          padding: EdgeInsets.only(
            bottom: horizontal ? 0 : reader.profile.pageGap,
            right: horizontal ? reader.profile.pageGap : 0,
          ),
          child: _Page(index: index, continuous: true),
        );
      },
    );
  }
}

/// One page, scaled the way the reader was told to scale it.
class _Page extends StatelessWidget {
  const _Page({required this.index, this.continuous = false});

  final int index;
  final bool continuous;

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).reader;
    final tokens = context.fundus;
    final file = reader.fileForPage(index);

    if (file == null) {
      // A placeholder with a page's proportions, so the strip does not jump
      // about while pages arrive.
      return AspectRatio(
        aspectRatio: continuous ? 2 / 3 : 1,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: tokens.textFaint,
            ),
          ),
        ),
      );
    }

    final image = Image.file(
      File(file),
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stack) => Center(
        child: Text(
          'Diese Seite lässt sich nicht anzeigen.',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: tokens.textFaint),
        ),
      ),
    );

    // In a continuous layout the width is the strip's width, whatever the
    // scale setting says — a webtoon that fits the screen height would be a
    // stamp.
    if (continuous) {
      return Image.file(
        File(file),
        width: double.infinity,
        fit: BoxFit.fitWidth,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stack) => const SizedBox.shrink(),
      );
    }

    return switch (reader.profile.pageScale) {
      PublicationPageScale.fitScreen => InteractiveViewer(
        maxScale: 6,
        child: SizedBox.expand(
          child: FittedBox(fit: BoxFit.contain, child: image),
        ),
      ),
      PublicationPageScale.fitWidth => SingleChildScrollView(
        child: Image.file(
          File(file),
          width: double.infinity,
          fit: BoxFit.fitWidth,
          filterQuality: FilterQuality.medium,
        ),
      ),
      PublicationPageScale.fitHeight => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox.expand(
          child: FittedBox(fit: BoxFit.fitHeight, child: image),
        ),
      ),
      PublicationPageScale.original => InteractiveViewer(
        constrained: false,
        maxScale: 6,
        child: image,
      ),
    };
  }
}

/// Saves the page on screen where the user wants it, and marks the spot.
Future<void> _savePage(BuildContext context) async {
  final scope = FundusScope.of(context);
  final reader = scope.reader;
  final messenger = ScaffoldMessenger.of(context);
  final bytes = await reader.capturePage();
  if (bytes == null) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Diese Seite liegt noch nicht bereit.')),
    );
    return;
  }
  try {
    final path = await scope.captureSink.save(
      bytes,
      suggestedName: reader.captureName(),
    );
    if (path == null) return;
    // Wie im alten Build: das gespeicherte Bild wird zugleich zum
    // Lesezeichen, sonst findet man die Stelle im Werk nie wieder.
    await reader.addBookmark(note: path);
    messenger.showSnackBar(SnackBar(content: Text('Seite gespeichert: $path')));
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(content: Text('Speichern fehlgeschlagen: $error')),
    );
  }
}

/// The reading settings — what the old reader had and this one was missing.
Future<void> _showReaderSettings(BuildContext context) {
  final reader = FundusScope.of(context).reader;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) {
        final profile = reader.profile;
        Future<void> update(PublicationReaderProfile value) async {
          setSheetState(() {});
          await reader.updateProfile(value);
          setSheetState(() {});
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              FundusSpace.x6,
              0,
              FundusSpace.x6,
              FundusSpace.x8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Lesen',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
                const SizedBox(height: FundusSpace.x6),
                _SettingGroup(
                  label: 'Anzeige',
                  children: [
                    for (final layout in PublicationReaderLayout.values)
                      ChoiceChip(
                        label: Text(layout.label),
                        selected: profile.layout == layout,
                        onSelected: (_) =>
                            update(profile.copyWith(layout: layout)),
                      ),
                  ],
                ),
                _SettingGroup(
                  label: 'Größe',
                  children: [
                    for (final scale in PublicationPageScale.values)
                      ChoiceChip(
                        label: Text(scale.label),
                        selected: profile.pageScale == scale,
                        onSelected: (_) =>
                            update(profile.copyWith(pageScale: scale)),
                      ),
                  ],
                ),
                _SettingGroup(
                  label: 'Leserichtung',
                  children: [
                    for (final direction in PublicationReadingDirection.values)
                      ChoiceChip(
                        label: Text(direction.label),
                        selected: profile.readingDirection == direction,
                        onSelected: (_) => update(
                          profile.copyWith(readingDirection: direction),
                        ),
                      ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Erste Seite ist das Cover'),
                  subtitle: const Text(
                    'Sonst steht sie in der ersten Doppelseite',
                  ),
                  value: profile.firstPageIsCover,
                  onChanged: (value) =>
                      update(profile.copyWith(firstPageIsCover: value)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Tippbereiche vertauschen'),
                  value: profile.invertTapZones,
                  onChanged: (value) =>
                      update(profile.copyWith(invertTapZones: value)),
                ),
                const SizedBox(height: FundusSpace.x4),
                Text(
                  'Breite der Tippbereiche',
                  style: Theme.of(sheetContext).textTheme.labelSmall,
                ),
                Slider(
                  value: profile.tapZoneWidth,
                  min: .15,
                  max: .45,
                  divisions: 6,
                  label: '${(profile.tapZoneWidth * 100).round()} %',
                  onChanged: (value) =>
                      update(profile.copyWith(tapZoneWidth: value)),
                ),
                Text(
                  'Seiten im Voraus laden',
                  style: Theme.of(sheetContext).textTheme.labelSmall,
                ),
                Slider(
                  value: profile.preloadCount.toDouble(),
                  min: 0,
                  max: 8,
                  divisions: 8,
                  label: '${profile.preloadCount}',
                  onChanged: (value) =>
                      update(profile.copyWith(preloadCount: value.round())),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _SettingGroup extends StatelessWidget {
  const _SettingGroup({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: FundusSpace.x6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: FundusSpace.x2),
        Wrap(
          spacing: FundusSpace.x2,
          runSpacing: FundusSpace.x2,
          children: children,
        ),
      ],
    ),
  );
}

/// The page overview: every page of the volume, to jump into.
Future<void> _showPageOverview(BuildContext context) {
  final reader = FundusScope.of(context).reader;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .6,
        child: GridView.builder(
          padding: const EdgeInsets.all(FundusSpace.x6),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 120,
            childAspectRatio: 2 / 3,
            mainAxisSpacing: FundusSpace.x3,
            crossAxisSpacing: FundusSpace.x3,
          ),
          itemCount: reader.pageCount,
          itemBuilder: (context, index) {
            final file = reader.fileForPage(index);
            final active = index == reader.pageIndex;
            return InkWell(
              onTap: () {
                reader.goToPage(index);
                Navigator.of(sheetContext).pop();
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: active
                        ? context.fundus.accentRamp.s400
                        : context.fundus.divider,
                    width: active ? 2 : 1,
                  ),
                  borderRadius: FundusRadius.smAll,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (file != null)
                      ClipRRect(
                        borderRadius: FundusRadius.smAll,
                        child: Image.file(
                          File(file),
                          fit: BoxFit.cover,
                          cacheWidth: 200,
                          errorBuilder: (context, error, stack) =>
                              const SizedBox.shrink(),
                        ),
                      ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        color: context.fundus.surface,
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '${index + 1}',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

Future<void> _showBookmarks(BuildContext context) {
  final reader = FundusScope.of(context).reader;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(FundusSpace.x6),
        children: [
          Text(
            'Lesezeichen',
            style: Theme.of(sheetContext).textTheme.titleMedium,
          ),
          const SizedBox(height: FundusSpace.x3),
          for (final bookmark in reader.bookmarks)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(bookmark.label ?? bookmark.displayPosition),
              subtitle: bookmark.note == null ? null : Text(bookmark.note!),
              onTap: () {
                reader.goToBookmark(bookmark);
                Navigator.of(sheetContext).pop();
              },
              trailing: IconButton(
                onPressed: () {
                  reader.deleteBookmark(bookmark.id);
                  Navigator.of(sheetContext).pop();
                },
                icon: Icon(FundusIcons.close, size: FundusIcons.sizeMd),
                tooltip: 'Entfernen',
              ),
            ),
        ],
      ),
    ),
  );
}
