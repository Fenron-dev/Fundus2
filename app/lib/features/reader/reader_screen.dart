import 'dart:async';
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

    // Die Leisten liegen über der Seite, nicht neben ihr.
    //
    // Als Spalte gebaut, änderte jedes Ein- und Ausblenden die Höhe der
    // Lesefläche — und ein Streifen, dessen Fenster sich ändert, rechnet
    // seine Position neu. Beim Tippen in die Mitte sprang das Bild deshalb
    // an den Anfang des Kapitels. Jetzt bleibt die Fläche, wie sie ist, und
    // die Leisten sind Gäste darüber.
    return ColoredBox(
      color: tokens.background,
      child: Stack(
        children: [
          const Positioned.fill(child: _ReaderSurface()),
          if (reader.showsChrome)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ColoredBox(
                color: tokens.background,
                child: const SafeArea(bottom: false, child: _ReaderBar()),
              ),
            ),
          // Die Leiste unten ist der Daumenbereich: das Kapitel davor, die
          // Leserichtung, das Kapitel danach — und wo man im Band steht.
          if (reader.showsChrome)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: ColoredBox(
                color: tokens.background,
                child: const SafeArea(top: false, child: _ChapterBar()),
              ),
            ),
        ],
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
              scope.leaveFullscreen();
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
            onPressed: scope.toggleFullscreen,
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
            scope.toggleFullscreen();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.escape:
            if (scope.fullscreen.isActive) {
              scope.leaveFullscreen();
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
    // Ist die Ansicht vergrößert, gehört jede Berührung ihr: wer eine
    // herangeholte Seite mit dem Finger verschiebt, blättert nicht um.
    return [
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: edge,
        // Kein Doppeltipp an den Rändern: dort wird geblättert, und zwei
        // Seiten schnell hintereinander sind zwei Tipps und kein Zoom.
        child: IgnorePointer(
          ignoring: reader.isZoomed,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: leftGoesBack ? reader.previousPage : reader.nextPage,
          ),
        ),
      ),
      Positioned(
        left: edge,
        right: edge,
        top: 0,
        bottom: 0,
        child: IgnorePointer(
          ignoring: reader.isZoomed,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: reader.toggleChrome,
            // Der Doppeltipp holt heran. Auf einem Telefon ist er die
            // verlässlichere Geste als das Kneifen, weil er sich mit dem
            // Scrollen des Streifens nicht streitet.
            onDoubleTap: reader.toggleZoom,
          ),
        ),
      ),
      Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        width: edge,
        child: IgnorePointer(
          ignoring: reader.isZoomed,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: leftGoesBack ? reader.nextPage : reader.previousPage,
          ),
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

    return _ZoomWindow(
      builder: (context, zoomed) => PageView.builder(
        controller: _controller,
        physics: zoomed ? const NeverScrollableScrollPhysics() : null,
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
      ),
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

  /// Ob der Streifen schon dort steht, wo zuletzt gelesen wurde.
  ///
  /// Bis dahin sagt er nichts. Eine Liste beginnt bei null, und die erste
  /// Meldung „ich sehe Seite eins" kam, bevor der gespeicherte Stand
  /// angesprungen war — sie überschrieb ihn. Aus Seite vier wurde so bei
  /// jedem Öffnen wieder Seite eins.
  bool _placed = false;

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
    if (!mounted || !_placed) return;
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
      // Der Sprungmerker wird *vorher* gesetzt. Sonst sieht der nächste
      // Aufbau eine geänderte Seitenzahl, hält sie für einen Sprung von
      // außen und zieht die Seite an die obere Kante — mitten im Scrollen.
      // Genau das war das Springen.
      _jumpedTo = best;
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
        _placed = true;
        Scrollable.ensureVisible(box, alignment: 0);
      });
    } else {
      _placed = true;
    }

    // Hineinzoomen gehört zum Lesen: eine Fußnote in einem Scan, ein Schild
    // im Hintergrund. Der Streifen bleibt dabei ein Streifen — gezoomt wird
    // die Ansicht, nicht die Seite, und beim Loslassen bleibt es, wo es ist,
    // bis jemand mit zwei Fingern zurückgeht.
    return _ZoomWindow(
      builder: (context, zoomed) => ListView.builder(
        controller: _scroll,
        // Ist etwas herangeholt, hält die Liste still: dann will man sich auf
        // der Seite bewegen, nicht weiterscrollen.
        physics: zoomed ? const NeverScrollableScrollPhysics() : null,
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
            // Eine Seite, die die Spalte nicht ausfüllt, gehört in die Mitte —
            // links angeschlagen liest sich ein Band schief.
            child: Center(child: _Page(index: index, continuous: true)),
          );
        },
      ),
    );
  }
}

/// Das Fenster auf die Seite, das sich heranholen lässt.
///
/// Hineinzoomen gehört zum Lesen: eine Fußnote in einem Scan, ein Schild im
/// Hintergrund. Vergrößert wird dabei die Ansicht, nicht die Seite — der
/// Streifen bleibt ein Streifen und die Reihe eine Reihe.
///
/// Solange nichts herangeholt ist, gehört jeder Wisch dem Blättern; sonst
/// fingen Liste und Zoom-Ansicht an, sich um jede Bewegung zu streiten, und
/// auf dem Telefon reagierte das Kneifen kaum. Ist etwas herangeholt, ist es
/// andersherum. Der Doppeltipp ist der verlässliche Weg dazwischen.
class _ZoomWindow extends StatefulWidget {
  const _ZoomWindow({required this.builder});

  final Widget Function(BuildContext context, bool zoomed) builder;

  @override
  State<_ZoomWindow> createState() => _ZoomWindowState();
}

class _ZoomWindowState extends State<_ZoomWindow> {
  final _view = TransformationController();

  /// Der Zählerstand, den dieses Fenster schon gesehen hat.
  ///
  /// Bei null zu beginnen hieß: ein Leser, der schon einmal herangeholt
  /// wurde, zählt höher, und das neue Fenster hielt den alten Stand für einen
  /// frischen Doppeltipp — beim Wiedereintritt war das Bild vergrößert, ohne
  /// dass jemand etwas getan hätte. Übernommen wird deshalb, was schon
  /// dasteht.
  int? _lastZoomRequest;

  /// Wie weit ein Doppeltipp heranholt: genug, um eine Fußnote zu lesen,
  /// nicht so weit, dass man sich verliert.
  static const _doubleTapScale = 2.5;

  @override
  void initState() {
    super.initState();
    _view.addListener(_reportZoom);
  }

  @override
  void dispose() {
    _view.removeListener(_reportZoom);
    _view.dispose();
    super.dispose();
  }

  double get _scale => _view.value.getMaxScaleOnAxis();
  bool get _zoomed => _scale > 1.01;

  void _reportZoom() {
    if (!mounted) return;
    setState(() {});
    FundusScope.of(context).reader.reportZoom(_scale);
  }

  /// Holt heran oder wieder weg — die Antwort auf einen Doppeltipp.
  void _toggleZoom() {
    _view.value = _zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..scaleByDouble(_doubleTapScale, _doubleTapScale, 1, 1));
  }

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).reader;
    // Der Doppeltipp kommt von den Tippflächen darüber; hier wird er
    // beantwortet.
    if (_lastZoomRequest == null) {
      _lastZoomRequest = reader.zoomRequest;
    } else if (_lastZoomRequest != reader.zoomRequest) {
      _lastZoomRequest = reader.zoomRequest;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _toggleZoom();
      });
    }

    return InteractiveViewer(
      transformationController: _view,
      maxScale: 5,
      panEnabled: _zoomed,
      scaleEnabled: true,
      child: widget.builder(context, _zoomed),
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
      // about while pages arrive. Where a page has already been measured, or
      // where its neighbours have, those proportions are used: a webtoon page
      // is a strip, and a 2:3 gap in its place moves everything below it the
      // moment the picture lands.
      return AspectRatio(
        aspectRatio: continuous ? (reader.aspectOf(index) ?? 2 / 3) : 1,
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

    // A continuous strip scrolls in one direction, so the scale setting
    // decides the other one: full width is the usual webtoon, but a wide
    // scan is readable only when it fits the screen instead.
    if (continuous) {
      return switch (reader.profile.pageScale) {
        PublicationPageScale.fitWidth ||
        // Nothing to fit a page into here — the strip has no page height.
        PublicationPageScale.fitScreen => _MeasuredPage(
          file: file,
          aspect: reader.aspectOf(index),
          onMeasured: (value) => reader.rememberAspect(index, value),
        ),
        PublicationPageScale.fitHeight => SizedBox(
          height: MediaQuery.sizeOf(context).height,
          child: Image.file(
            File(file),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stack) => const SizedBox.shrink(),
          ),
        ),
        PublicationPageScale.original => _CentredScroll(child: image),
      };
    }

    return switch (reader.profile.pageScale) {
      // Herangeholt wird eine Ebene höher, für die ganze Ansicht; ein
      // zweiter Zoom in der Seite selbst stritte mit ihm um jede Berührung.
      PublicationPageScale.fitScreen => SizedBox.expand(
        child: FittedBox(fit: BoxFit.contain, child: image),
      ),
      PublicationPageScale.fitWidth => SingleChildScrollView(
        child: Image.file(
          File(file),
          width: double.infinity,
          fit: BoxFit.fitWidth,
          filterQuality: FilterQuality.medium,
        ),
      ),
      PublicationPageScale.fitHeight => LayoutBuilder(
        builder: (context, constraints) => _CentredScroll(
          child: SizedBox(
            height: constraints.maxHeight,
            child: Image.file(
              File(file),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
            ),
          ),
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

/// The marks of this work — as a grid of pages, or as a list.
///
/// „Seite 143" tells nobody anything; the page itself does. Which of the two
/// is wanted is the same choice the library offers everywhere else, so it is
/// the same switch.
Future<void> _showBookmarks(BuildContext context) {
  final reader = FundusScope.of(context).reader;
  reader.requestBookmarkPreviews();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => const _BookmarkSheet(),
  );
}

class _BookmarkSheet extends StatefulWidget {
  const _BookmarkSheet();

  @override
  State<_BookmarkSheet> createState() => _BookmarkSheetState();
}

class _BookmarkSheetState extends State<_BookmarkSheet> {
  bool _grid = true;

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).reader;
    final bookmarks = reader.bookmarks;

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                FundusSpace.x6,
                0,
                FundusSpace.x4,
                FundusSpace.x3,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Lesezeichen',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => _grid = true),
                    isSelected: _grid,
                    icon: Icon(FundusIcons.viewGrid, size: FundusIcons.sizeMd),
                    tooltip: 'Als Raster',
                  ),
                  IconButton(
                    onPressed: () => setState(() => _grid = false),
                    isSelected: !_grid,
                    icon: Icon(FundusIcons.viewTable, size: FundusIcons.sizeMd),
                    tooltip: 'Als Liste',
                  ),
                ],
              ),
            ),
            if (bookmarks.isEmpty)
              const Expanded(
                child: FundusEmptyState(
                  title: 'Noch keine Lesezeichen',
                  reason: 'Setze eins über das Lesezeichen-Symbol oben.',
                ),
              )
            else
              Expanded(
                child: _grid
                    ? _BookmarkGrid(bookmarks: bookmarks)
                    : _BookmarkList(bookmarks: bookmarks),
              ),
          ],
        ),
      ),
    );
  }
}

class _BookmarkGrid extends StatelessWidget {
  const _BookmarkGrid({required this.bookmarks});

  final List<LibraryBookmark> bookmarks;

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).reader;
    final tokens = context.fundus;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        FundusSpace.x6,
        0,
        FundusSpace.x6,
        FundusSpace.x6,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150,
        childAspectRatio: .58,
        mainAxisSpacing: FundusSpace.x4,
        crossAxisSpacing: FundusSpace.x4,
      ),
      itemCount: bookmarks.length,
      itemBuilder: (context, index) {
        final bookmark = bookmarks[index];
        final preview = reader.previewForBookmark(bookmark);
        return InkWell(
          onTap: () {
            reader.goToBookmark(bookmark);
            Navigator.of(context).pop();
          },
          onLongPress: () {
            reader.deleteBookmark(bookmark.id);
            Navigator.of(context).pop();
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: tokens.surface,
                    border: Border.all(color: tokens.divider),
                    borderRadius: FundusRadius.mdAll,
                  ),
                  child: preview == null
                      // A mark in another volume has no page to show until
                      // that volume is open; the number still stands.
                      ? Center(
                          child: Icon(
                            FundusIcons.bookmark,
                            size: FundusIcons.sizeLg,
                            color: tokens.textFaint,
                          ),
                        )
                      : ClipRRect(
                          borderRadius: FundusRadius.mdAll,
                          child: Image.file(
                            File(preview),
                            fit: BoxFit.cover,
                            width: double.infinity,
                            cacheWidth: 300,
                            errorBuilder: (context, error, stack) =>
                                const SizedBox.shrink(),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: FundusSpace.x2),
              Text(
                bookmark.label ?? bookmark.displayPosition,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BookmarkList extends StatelessWidget {
  const _BookmarkList({required this.bookmarks});

  final List<LibraryBookmark> bookmarks;

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).reader;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        FundusSpace.x6,
        0,
        FundusSpace.x6,
        FundusSpace.x6,
      ),
      children: [
        for (final bookmark in bookmarks)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: _BookmarkThumb(bookmark: bookmark),
            title: Text(bookmark.label ?? bookmark.displayPosition),
            subtitle: bookmark.note == null ? null : Text(bookmark.note!),
            onTap: () {
              reader.goToBookmark(bookmark);
              Navigator.of(context).pop();
            },
            trailing: IconButton(
              onPressed: () {
                reader.deleteBookmark(bookmark.id);
                Navigator.of(context).pop();
              },
              icon: Icon(FundusIcons.close, size: FundusIcons.sizeMd),
              tooltip: 'Entfernen',
            ),
          ),
      ],
    );
  }
}

class _BookmarkThumb extends StatelessWidget {
  const _BookmarkThumb({required this.bookmark});

  final LibraryBookmark bookmark;

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).reader;
    final tokens = context.fundus;
    final preview = reader.previewForBookmark(bookmark);
    return SizedBox(
      width: 34,
      height: 48,
      child: preview == null
          ? Icon(
              FundusIcons.bookmark,
              size: FundusIcons.sizeMd,
              color: tokens.textFaint,
            )
          : ClipRRect(
              borderRadius: FundusRadius.smAll,
              child: Image.file(
                File(preview),
                fit: BoxFit.cover,
                cacheWidth: 100,
                errorBuilder: (context, error, stack) =>
                    const SizedBox.shrink(),
              ),
            ),
    );
  }
}

/// A page wider than the window scrolls sideways; one narrower than it sits
/// in the middle. A scroll view alone would pin it to the left edge.
class _CentredScroll extends StatelessWidget {
  const _CentredScroll({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: constraints.maxWidth),
        child: Center(child: child),
      ),
    ),
  );
}

/// One page of a strip, at a height that is known before it is drawn.
///
/// An image reports its proportions only once it has been decoded. Until then
/// it takes no room, so the strip grew under the reader's thumb every time a
/// page arrived — the jumping this is about. The page is therefore laid out
/// at the proportions the reader already knows, and what it measures on the
/// way is handed back so the next page after it is right from the start.
class _MeasuredPage extends StatefulWidget {
  const _MeasuredPage({
    required this.file,
    required this.aspect,
    required this.onMeasured,
  });

  final String file;
  final double? aspect;
  final ValueChanged<double> onMeasured;

  @override
  State<_MeasuredPage> createState() => _MeasuredPageState();
}

class _MeasuredPageState extends State<_MeasuredPage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _measured;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listen();
  }

  @override
  void didUpdateWidget(_MeasuredPage old) {
    super.didUpdateWidget(old);
    if (old.file != widget.file) {
      _measured = null;
      _listen();
    }
  }

  void _listen() {
    _detach();
    final provider = FileImage(File(widget.file));
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((info, _) {
      // Das Bild selbst gehört dem Cache; hier wird nur ausgemessen.
      final aspect = info.image.width / info.image.height;
      if (!mounted || !aspect.isFinite || aspect <= 0) return;
      widget.onMeasured(aspect);
      if (_measured != aspect) setState(() => _measured = aspect);
    }, onError: (_, _) {});
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  void _detach() {
    if (_stream case final stream? when _listener != null) {
      stream.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final aspect = _measured ?? widget.aspect;
    final image = Image.file(
      File(widget.file),
      width: double.infinity,
      fit: BoxFit.fitWidth,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
    );
    if (aspect == null) return image;
    return AspectRatio(aspectRatio: aspect, child: image);
  }
}

/// Chapter to chapter, and where in this one.
///
/// A long strip has no page turns to speak of, so the one thing a hand needs
/// within reach at the bottom is: what comes before, what comes after, and
/// how far along this chapter is. The middle button switches the way of
/// reading, because that is a decision one makes about a work while looking
/// at it, not in a settings page.
class _ChapterBar extends StatelessWidget {
  const _ChapterBar();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final reader = scope.reader;
    final tokens = context.fundus;
    final theme = Theme.of(context);
    final volumes = reader.volumes;
    final index = reader.volumeIndex;
    final pages = reader.pageCount;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          FundusSpace.x4,
          FundusSpace.x2,
          FundusSpace.x4,
          FundusSpace.x2,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (pages > 1)
              Row(
                children: [
                  Text(
                    '${reader.pageIndex + 1}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: tokens.textFaint,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: reader.pageIndex.clamp(0, pages - 1).toDouble(),
                      max: (pages - 1).toDouble(),
                      onChanged: (value) => reader.goToPage(value.round()),
                    ),
                  ),
                  Text(
                    '$pages',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: tokens.textFaint,
                    ),
                  ),
                ],
              ),
            // Nur Pfeile, kein Kapitelname: ein Name wie „Rebirth - Kapitel
            // 0280 - Der lange Weg zurück" füllt allein die ganze Zeile und
            // ist trotzdem abgeschnitten. Welches Kapitel läuft, steht oben.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  onPressed: index > 0
                      ? () => unawaited(reader.openVolume(index - 1))
                      : null,
                  icon: Icon(FundusIcons.back, size: FundusIcons.sizeMd),
                  tooltip: 'Vorheriges Kapitel',
                ),
                OutlinedButton.icon(
                  onPressed: () => unawaited(
                    reader.updateProfile(
                      reader.profile.copyWith(
                        layout: nextComicLayout(reader.profile.layout),
                      ),
                    ),
                  ),
                  icon: Icon(FundusIcons.sort, size: FundusIcons.sizeSm),
                  label: Text(comicLayoutLabel(reader.profile.layout)),
                ),
                IconButton(
                  onPressed: index + 1 < volumes.length
                      ? () => unawaited(reader.openVolume(index + 1))
                      : null,
                  icon: Icon(FundusIcons.forward, size: FundusIcons.sizeMd),
                  tooltip: 'Nächstes Kapitel',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
