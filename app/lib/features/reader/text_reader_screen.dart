import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';
import '../../media/text_reader_controller.dart';

/// The reader for running text, laid over the shell.
///
/// A novel is not a comic: the unit is a place in a chapter, the setting that
/// matters is the type, and the page turns itself as the text scrolls.
class TextReaderScreen extends StatelessWidget {
  const TextReaderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final reader = scope.textReader;
    final work = reader.work;
    if (work == null) return const SizedBox.shrink();

    return ColoredBox(
      color: _background(context, reader.profile.theme),
      child: SafeArea(
        top: reader.showsChrome,
        bottom: false,
        child: Column(
          children: [
            if (reader.showsChrome) const _TextReaderBar(),
            const Expanded(child: _TextSurface()),
            // Die Leiste unten ist der Daumenbereich, wie beim Manga-Leser:
            // das Kapitel davor, wo man steht, das Kapitel danach. Am Fuß
            // eines Kapitels steht dasselbe noch einmal — dort aber erst,
            // wenn man unten angekommen ist.
            if (reader.showsChrome && reader.chapters.length > 1)
              const _TextChapterBar(),
          ],
        ),
      ),
    );
  }
}

/// Paper, sepia and night are reading choices, not the app's theme — a book
/// read at midnight wants a different ground than the library around it.
Color _background(BuildContext context, ReflowTheme theme) => switch (theme) {
  ReflowTheme.followApp => context.fundus.background,
  ReflowTheme.paper => const Color(0xFFF6F3EC),
  ReflowTheme.sepia => const Color(0xFFF3E7D0),
  ReflowTheme.night => const Color(0xFF12121A),
};

Color _foreground(BuildContext context, ReflowTheme theme) => switch (theme) {
  ReflowTheme.followApp => context.fundus.text,
  ReflowTheme.paper => const Color(0xFF1C1B18),
  ReflowTheme.sepia => const Color(0xFF3A2F21),
  ReflowTheme.night => const Color(0xFFC9C9D4),
};

class _TextReaderBar extends StatelessWidget {
  const _TextReaderBar();

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final reader = scope.textReader;
    final work = reader.work!;
    final theme = Theme.of(context);
    final ink = _foreground(context, reader.profile.theme);

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
            icon: Icon(FundusIcons.close, size: FundusIcons.sizeLg, color: ink),
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
                  style: theme.textTheme.titleMedium?.copyWith(color: ink),
                ),
                Text(
                  reader.positionLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: ink.withValues(alpha: .6),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: reader.addBookmark,
            icon: Icon(
              FundusIcons.bookmark,
              size: FundusIcons.sizeLg,
              color: ink,
            ),
            tooltip: 'Lesezeichen setzen',
          ),
          if (reader.bookmarks.isNotEmpty)
            IconButton(
              onPressed: () => _showTextBookmarks(context),
              icon: Icon(
                FundusIcons.note,
                size: FundusIcons.sizeLg,
                color: ink,
              ),
              tooltip: 'Lesezeichen',
            ),
          if (reader.chapters.length > 1 || reader.volumes.length > 1)
            const _ChapterMenu(),
          IconButton(
            onPressed: () => _showTextSettings(context),
            icon: Icon(
              FundusIcons.settings,
              size: FundusIcons.sizeLg,
              color: ink,
            ),
            tooltip: 'Schrift und Satz',
          ),
          // Kein Vollbild-Knopf mehr: der Leser geht ohnehin ins Vollbild,
          // sobald die Leiste weg ist. An seiner Stelle das, was beim Lesen
          // entsteht.
          // Immer da, auch wenn noch nichts markiert ist: eine Funktion, die
          // erst auftaucht, wenn man sie benutzt hat, findet niemand.
          IconButton(
            onPressed: () => _showHighlights(context),
            icon: Icon(FundusIcons.edit, size: FundusIcons.sizeLg, color: ink),
            tooltip: 'Markierungen',
          ),
        ],
      ),
    );
  }
}

class _ChapterMenu extends StatelessWidget {
  const _ChapterMenu();

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).textReader;
    final ink = _foreground(context, reader.profile.theme);
    return PopupMenuButton<({bool volume, int index})>(
      tooltip: 'Inhalt',
      icon: Icon(FundusIcons.lists, size: FundusIcons.sizeLg, color: ink),
      onSelected: (choice) => choice.volume
          ? reader.openVolume(choice.index)
          : reader.goToChapter(choice.index),
      itemBuilder: (context) => [
        if (reader.volumes.length > 1) ...[
          const PopupMenuItem(enabled: false, child: Text('BÄNDE')),
          for (var index = 0; index < reader.volumes.length; index++)
            PopupMenuItem(
              value: (volume: true, index: index),
              child: Text(
                reader.volumes[index].title,
                style: index == reader.volumeIndex
                    ? TextStyle(color: context.fundus.accentRamp.s200)
                    : null,
              ),
            ),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem(enabled: false, child: Text('KAPITEL')),
        for (var index = 0; index < reader.chapters.length; index++)
          PopupMenuItem(
            value: (volume: false, index: index),
            child: Text(
              reader.chapters[index].title,
              style: index == reader.chapterIndex
                  ? TextStyle(color: context.fundus.accentRamp.s200)
                  : null,
            ),
          ),
      ],
    );
  }
}

/// The text itself.
class _TextSurface extends StatefulWidget {
  const _TextSurface();

  @override
  State<_TextSurface> createState() => _TextSurfaceState();
}

class _TextSurfaceState extends State<_TextSurface> {
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  int _lastJump = -1;
  TextReaderController? _reader;

  /// The paragraph the view is still travelling to, or null when it is where
  /// it belongs.
  ///
  /// A list builds what is near the screen and nothing else, so the paragraph
  /// somebody stopped at on page two hundred has no widget to jump to when
  /// the chapter opens. The jump used to look it up once, find nothing and
  /// give up in silence — and then the first scroll report overwrote the
  /// stored position with „paragraph 0". The book was never lost; the view
  /// simply never went there, and then said so.
  int? _travellingTo;
  int _steps = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_report);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Held rather than looked up per frame: the scroll listener runs outside
    // a build, where asking an inherited widget for the scope is both wrong
    // and, sixty times a second, not free.
    _reader = FundusScope.of(context).textReader;
  }

  @override
  void dispose() {
    _scroll.removeListener(_report);
    _scroll.dispose();
    super.dispose();
  }

  /// Which paragraph is at the top, and how far into it the reader is.
  ///
  /// Only the built paragraphs are measured — a list builds what is near the
  /// screen — so this stays a handful of comparisons per scroll.
  void _report() {
    if (!mounted) return;
    final reader = _reader;
    if (reader == null) return;
    // While the view is still travelling to the saved place, what is on
    // screen is not where anybody is reading, and must not be written down as
    // if it were.
    if (_travellingTo != null || reader.isBusy) return;
    final viewport = context.findRenderObject();
    if (viewport is! RenderBox) return;

    int? best;
    var bestTop = double.negativeInfinity;
    double? bestHeight;
    for (final entry in _keys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      // The last paragraph that starts at or above the top edge is the one
      // being read.
      if (top <= 0 && top > bestTop) {
        bestTop = top;
        best = entry.key;
        bestHeight = box.size.height;
      }
    }
    if (best == null) return;
    final height = bestHeight ?? 1;
    reader.reportPosition(
      best,
      height <= 0 ? 0 : (-bestTop / height).clamp(0, 1),
    );
  }

  /// Walks the view down to [target], building what it needs on the way.
  ///
  /// The first step is a guess from the paragraph's share of the chapter,
  /// which lands close in one jump for evenly-sized prose. After that it
  /// checks whether the paragraph exists yet and, if not, scrolls a screen
  /// further and looks again — each step builds more of the list, so it
  /// converges. The step count is bounded: a chapter that will not cooperate
  /// costs a wrong position, never a locked-up reader.
  void _travelTo(int target, int paragraphCount) {
    if (target <= 0 || paragraphCount <= 1) {
      _travellingTo = null;
      return;
    }
    _travellingTo = target;
    _steps = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) {
        _travellingTo = null;
        return;
      }
      final extent = _scroll.position.maxScrollExtent;
      if (extent > 0) {
        _scroll.jumpTo((extent * (target / paragraphCount)).clamp(0.0, extent));
      }
      _stepTowards(target);
    });
  }

  void _stepTowards(int target) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _travellingTo != target) return;
      if (!_scroll.hasClients) {
        _travellingTo = null;
        return;
      }
      final anchor = _keys[target]?.currentContext;
      if (anchor != null) {
        Scrollable.ensureVisible(anchor, alignment: 0);
        // One more frame before reporting resumes, so the position that is
        // written down is the one the jump arrived at.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_travellingTo == target) _travellingTo = null;
        });
        return;
      }
      if (_steps++ > 120) {
        _travellingTo = null;
        return;
      }
      final position = _scroll.position;
      if (position.pixels >= position.maxScrollExtent) {
        _travellingTo = null;
        return;
      }
      _scroll.jumpTo(
        (position.pixels + position.viewportDimension * .8).clamp(
          0.0,
          position.maxScrollExtent,
        ),
      );
      _stepTowards(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final reader = scope.textReader;
    final failure = reader.failure;

    if (failure != null) {
      return Padding(
        padding: const EdgeInsets.all(FundusSpace.x10),
        child: FundusEmptyState(
          icon: FundusIcons.warning,
          title: 'Dieser Text lässt sich nicht öffnen',
          reason: failure,
        ),
      );
    }

    final paragraphs = reader.paragraphs;
    if (paragraphs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final profile = reader.profile;
    final ink = _foreground(context, profile.theme);

    // A jump has to move the view; a scroll of the reader's own must not be
    // answered with one. The counter is what tells them apart — a paragraph
    // number cannot.
    if (_lastJump != reader.jumpRevision) {
      _lastJump = reader.jumpRevision;
      // Each chapter measures its own paragraphs. Keeping the keys of the
      // last one means measuring detached boxes on every scrolled frame, and
      // the map grows for as long as the book is open.
      _keys.clear();
      _travelTo(reader.paragraphIndex, paragraphs.length);
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        switch (event.logicalKey) {
          case LogicalKeyboardKey.arrowRight:
            reader.nextChapter();
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowLeft:
            reader.previousChapter();
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
      child: _MenuGesture(
        gesture: profile.menuGesture,
        onTap: reader.toggleChrome,
        child: Scrollbar(
          controller: _scroll,
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(
              horizontal: FundusSpace.x6,
              vertical: FundusSpace.x10,
            ),
            // One past the paragraphs: the chapter's foot carries the way on.
            itemCount: paragraphs.length + 1,
            itemBuilder: (context, index) {
              if (index == paragraphs.length) {
                return _ChapterFoot(width: profile.contentWidth);
              }
              final key = _keys.putIfAbsent(index, GlobalKey.new);
              return Center(
                key: key,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: profile.contentWidth),
                  child: Padding(
                    padding: EdgeInsets.only(bottom: profile.paragraphSpacing),
                    child: _Paragraph(index: index, ink: ink),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// One paragraph, with its marks drawn in and its selection markable.
class _Paragraph extends StatefulWidget {
  const _Paragraph({required this.index, required this.ink});

  final int index;
  final Color ink;

  @override
  State<_Paragraph> createState() => _ParagraphState();
}

class _ParagraphState extends State<_Paragraph> {
  TextSelection? _selection;

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).textReader;
    final profile = reader.profile;
    final paragraphs = reader.paragraphs;
    if (widget.index >= paragraphs.length) return const SizedBox.shrink();
    final text = paragraphs[widget.index].text;
    final marks = reader.highlightsInParagraph(widget.index);

    final font = fontFor(profile.fontFamily);
    final style = TextStyle(
      color: widget.ink,
      fontSize: profile.fontSize,
      height: profile.lineHeight,
      fontFamily: font.family,
      fontFamilyFallback: font.fallback,
    );

    return SelectableText.rich(
      TextSpan(children: _spans(text, marks)),
      style: style,
      onSelectionChanged: (selection, cause) => _selection = selection,
      contextMenuBuilder: (context, state) {
        final selection = _selection;
        final selected = selection != null && !selection.isCollapsed;
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: state.contextMenuAnchors,
          // „Markieren" steht vorn, nicht hinter Ausschneiden, Kopieren und
          // Einfügen: die Leiste ist auf einem Telefon schmal, und was hinten
          // steht, findet niemand.
          buttonItems: [
            if (selected)
              ContextMenuButtonItem(
                label: 'Markieren',
                onPressed: () {
                  reader.addHighlight(
                    paragraphIndex: widget.index,
                    start: selection.start,
                    end: selection.end,
                  );
                  state.hideToolbar();
                },
              ),
            for (final mark in marks)
              if (selected &&
                  selection.start < mark.end &&
                  selection.end > mark.start)
                ContextMenuButtonItem(
                  label: 'Markierung entfernen',
                  onPressed: () {
                    reader.deleteHighlight(mark.highlight.id);
                    state.hideToolbar();
                  },
                ),
            ...state.contextMenuButtonItems,
          ],
        );
      },
    );
  }

  /// Splits the paragraph into the runs between its marks.
  List<TextSpan> _spans(
    String text,
    List<({LibraryHighlight highlight, int start, int end})> marks,
  ) {
    if (marks.isEmpty) return [TextSpan(text: text)];
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final mark in marks) {
      // Marks can overlap; the later one starts where the previous ended
      // rather than drawing over it.
      final start = mark.start.clamp(cursor, text.length);
      final end = mark.end.clamp(start, text.length);
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(start, end),
          style: TextStyle(
            backgroundColor: _markColor(mark.highlight.color),
            color: const Color(0xFF1C1B18),
          ),
        ),
      );
      cursor = end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return spans;
  }

  static Color _markColor(String value) {
    final hex = value.replaceAll('#', '');
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return const Color(0xFFFFF176);
    return Color(hex.length <= 6 ? 0xFF000000 | parsed : parsed);
  }
}

/// The families to try for a reading font, in order.
///
/// „serif" and „sans-serif" are CSS names, not font families: handing them to
/// Flutter names nothing, the system font is used, and choosing a font does
/// nothing at all. Real names have to be asked for, several per choice,
/// because a Mac and an Android phone ship different ones.
const _fontStacks = <ReflowFontFamily, List<String>>{
  ReflowFontFamily.serif: [
    'Georgia',
    'Iowan Old Style',
    'Times New Roman',
    'Noto Serif',
    'Droid Serif',
    'serif',
  ],
  ReflowFontFamily.sansSerif: [
    'Helvetica Neue',
    'Helvetica',
    'Arial',
    'Roboto',
    'Noto Sans',
    'sans-serif',
  ],
  ReflowFontFamily.monospace: [
    'Menlo',
    'SF Mono',
    'Consolas',
    'Roboto Mono',
    'Noto Sans Mono',
    'monospace',
  ],
};

/// The font to ask for, and what to fall back to when it is not installed.
({String? family, List<String>? fallback}) fontFor(ReflowFontFamily family) {
  final stack = _fontStacks[family];
  if (stack == null) return (family: null, fallback: null);
  return (family: stack.first, fallback: stack.sublist(1));
}

class _ChapterFoot extends StatelessWidget {
  const _ChapterFoot({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).textReader;
    final last =
        reader.chapterIndex + 1 >= reader.chapters.length &&
        reader.volumeIndex + 1 >= reader.volumes.length;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Padding(
          padding: const EdgeInsets.only(
            top: FundusSpace.x8,
            bottom: FundusSpace.x16,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton.icon(
                onPressed: reader.chapterIndex == 0 && reader.volumeIndex == 0
                    ? null
                    : reader.previousChapter,
                icon: Icon(FundusIcons.back, size: FundusIcons.sizeSm),
                label: const Text('Vorheriges Kapitel'),
              ),
              if (!last)
                FilledButton.icon(
                  onPressed: reader.nextChapter,
                  icon: Icon(FundusIcons.forward, size: FundusIcons.sizeSm),
                  label: const Text('Nächstes Kapitel'),
                )
              else
                Text(
                  'Ende',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: context.fundus.textFaint,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showTextSettings(BuildContext context) {
  final reader = FundusScope.of(context).textReader;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) {
        final profile = reader.profile;
        Future<void> update(ReflowReaderProfile value) async {
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
                  'Schrift und Satz',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
                const SizedBox(height: FundusSpace.x6),
                Text(
                  'Schrift',
                  style: Theme.of(sheetContext).textTheme.labelSmall,
                ),
                const SizedBox(height: FundusSpace.x2),
                Wrap(
                  spacing: FundusSpace.x2,
                  runSpacing: FundusSpace.x2,
                  children: [
                    for (final family in ReflowFontFamily.values)
                      ChoiceChip(
                        // Jede Schrift zeigt sich selbst; sonst wählt man
                        // einen Namen und sieht erst hinterher, was er tut.
                        label: Builder(
                          builder: (context) {
                            final font = fontFor(family);
                            return Text(
                              _familyLabel(family),
                              style: TextStyle(
                                fontFamily: font.family,
                                fontFamilyFallback: font.fallback,
                              ),
                            );
                          },
                        ),
                        selected: profile.fontFamily == family,
                        onSelected: (_) =>
                            update(profile.copyWith(fontFamily: family)),
                      ),
                  ],
                ),
                const SizedBox(height: FundusSpace.x6),
                Text(
                  'Papier',
                  style: Theme.of(sheetContext).textTheme.labelSmall,
                ),
                const SizedBox(height: FundusSpace.x2),
                Wrap(
                  spacing: FundusSpace.x2,
                  runSpacing: FundusSpace.x2,
                  children: [
                    for (final theme in ReflowTheme.values)
                      ChoiceChip(
                        label: Text(_themeLabel(theme)),
                        selected: profile.theme == theme,
                        onSelected: (_) =>
                            update(profile.copyWith(theme: theme)),
                      ),
                  ],
                ),
                const SizedBox(height: FundusSpace.x6),
                Text(
                  'Leiste öffnen mit',
                  style: Theme.of(sheetContext).textTheme.labelSmall,
                ),
                const SizedBox(height: FundusSpace.x2),
                Wrap(
                  spacing: FundusSpace.x2,
                  runSpacing: FundusSpace.x2,
                  children: [
                    for (final gesture in ReaderMenuGesture.values)
                      ChoiceChip(
                        label: Text(gesture.label),
                        selected: profile.menuGesture == gesture,
                        onSelected: (_) =>
                            update(profile.copyWith(menuGesture: gesture)),
                      ),
                  ],
                ),
                const SizedBox(height: FundusSpace.x2),
                Text(
                  'Ein einzelner Tipp trifft im Text meist ein Wort und '
                  'markiert es. Zwei Finger meinen nie eine Textstelle.',
                  style: Theme.of(sheetContext).textTheme.labelSmall?.copyWith(
                    color: context.fundus.textFaint,
                  ),
                ),
                const SizedBox(height: FundusSpace.x6),
                _Measure(
                  label: 'Schriftgröße',
                  value: profile.fontSize,
                  min: 12,
                  max: 40,
                  unit: 'pt',
                  onChanged: (value) =>
                      update(profile.copyWith(fontSize: value)),
                ),
                _Measure(
                  label: 'Zeilenabstand',
                  value: profile.lineHeight,
                  min: 1.1,
                  max: 2.4,
                  digits: 2,
                  onChanged: (value) =>
                      update(profile.copyWith(lineHeight: value)),
                ),
                _Measure(
                  label: 'Satzbreite',
                  value: profile.contentWidth,
                  min: 320,
                  max: 1400,
                  unit: 'px',
                  onChanged: (value) =>
                      update(profile.copyWith(contentWidth: value)),
                ),
                _Measure(
                  label: 'Absatzabstand',
                  value: profile.paragraphSpacing,
                  min: 0,
                  max: 48,
                  unit: 'px',
                  onChanged: (value) =>
                      update(profile.copyWith(paragraphSpacing: value)),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _Measure extends StatelessWidget {
  const _Measure({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.unit = '',
    this.digits = 0,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String unit;
  final int digits;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '$label · ${value.toStringAsFixed(digits)}$unit',
        style: Theme.of(context).textTheme.labelSmall,
      ),
      Slider(value: value, min: min, max: max, onChanged: onChanged),
    ],
  );
}

String _familyLabel(ReflowFontFamily family) => switch (family) {
  ReflowFontFamily.system => 'Systemschrift',
  ReflowFontFamily.serif => 'Serif',
  ReflowFontFamily.sansSerif => 'Sans Serif',
  ReflowFontFamily.monospace => 'Monospace',
};

String _themeLabel(ReflowTheme theme) => switch (theme) {
  ReflowTheme.followApp => 'Wie die App',
  ReflowTheme.paper => 'Papier',
  ReflowTheme.sepia => 'Sepia',
  ReflowTheme.night => 'Nacht',
};

Future<void> _showTextBookmarks(BuildContext context) {
  final reader = FundusScope.of(context).textReader;
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

/// Was beim Lesen entstanden ist: die markierten Stellen.
///
/// Eine Markierung ohne Wiedersehen ist eine Notiz in einer Schublade. Hier
/// stehen sie beisammen, führen zurück an ihre Stelle — und lassen sich als
/// Textdatei mitnehmen, denn sie gehören dem, der sie gemacht hat, und nicht
/// dieser Anwendung.
Future<void> _showHighlights(BuildContext context) {
  final reader = FundusScope.of(context).textReader;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(FundusSpace.x6),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Markierungen',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              TextButton.icon(
                onPressed: reader.highlights.isEmpty
                    ? null
                    : () => unawaited(_exportHighlights(sheetContext)),
                icon: Icon(FundusIcons.downloads, size: FundusIcons.sizeSm),
                label: const Text('Sichern'),
              ),
            ],
          ),
          const SizedBox(height: FundusSpace.x3),
          if (reader.highlights.isEmpty)
            Text(
              'Noch nichts markiert. Eine Stelle im Text auswählen und '
              '„Markieren" wählen.',
              style: Theme.of(
                sheetContext,
              ).textTheme.bodyMedium?.copyWith(color: context.fundus.textFaint),
            ),
          for (final mark in reader.highlights)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(mark.quote),
              subtitle: Text(
                mark.note == null
                    ? mark.mediaPosition.displayValue
                    : '${mark.mediaPosition.displayValue} · ${mark.note}',
              ),
              trailing: IconButton(
                onPressed: () {
                  reader.deleteHighlight(mark.id);
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

/// Schreibt die Markierungen als Textdatei weg.
Future<void> _exportHighlights(BuildContext context) async {
  final reader = FundusScope.of(context).textReader;
  final work = reader.work;
  if (work == null || reader.highlights.isEmpty) return;
  final lines = StringBuffer()
    ..writeln('# ${work.title}')
    ..writeln();
  for (final mark in reader.highlights) {
    lines
      ..writeln('> ${mark.quote}')
      ..writeln();
    if (mark.note case final note? when note.isNotEmpty) {
      lines
        ..writeln(note)
        ..writeln();
    }
    lines
      ..writeln('— ${mark.mediaPosition.displayValue}')
      ..writeln();
  }
  final safe = work.title.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
  final target = await FilePicker.saveFile(
    dialogTitle: 'Markierungen sichern',
    fileName: '${safe.isEmpty ? 'Markierungen' : safe} — Markierungen.md',
  );
  if (target == null) return;
  await File(target).writeAsString(lines.toString());
  if (!context.mounted) return;
  Navigator.of(context).pop();
}

/// Womit die Leiste kommt und geht.
///
/// Ein einfacher Tipp auf den Text geht unter: die Textauswahl greift zuerst,
/// und dann steht ein Wort markiert da statt eines Menüs offen. Zwei Finger
/// sind eindeutig — sie meinen nie eine Textstelle. Gehört wird über einen
/// [Listener], nicht über eine Geste: der mischt sich nicht in den Streit um
/// die Berührung ein, also bleibt das Markieren, wie es war.
class _MenuGesture extends StatefulWidget {
  const _MenuGesture({
    required this.gesture,
    required this.onTap,
    required this.child,
  });

  final ReaderMenuGesture gesture;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_MenuGesture> createState() => _MenuGestureState();
}

class _MenuGestureState extends State<_MenuGesture> {
  final _down = <int, Offset>{};
  int _fingers = 0;
  DateTime? _startedAt;
  bool _moved = false;

  /// Was noch als Tipp durchgeht: kurz genug und ohne zu wandern.
  static const _window = Duration(milliseconds: 600);
  static const _slop = 16.0;

  void _reset() {
    _fingers = 0;
    _startedAt = null;
    _moved = false;
  }

  void _onDown(PointerDownEvent event) {
    if (_down.isEmpty) _reset();
    _down[event.pointer] = event.position;
    if (_down.length > _fingers) _fingers = _down.length;
    _startedAt ??= DateTime.now();
  }

  void _onMove(PointerMoveEvent event) {
    final start = _down[event.pointer];
    if (start == null) return;
    if ((event.position - start).distance > _slop) _moved = true;
  }

  void _onUp(PointerEvent event) {
    _down.remove(event.pointer);
    if (_down.isNotEmpty) return;
    final started = _startedAt;
    final short =
        started != null && DateTime.now().difference(started) < _window;
    if (short && !_moved && _fingers == 2) widget.onTap();
    _reset();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.gesture == ReaderMenuGesture.tap) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        child: widget.child,
      );
    }
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      child: widget.child,
    );
  }
}

/// Kapitel vor und zurück, im Daumenbereich.
class _TextChapterBar extends StatelessWidget {
  const _TextChapterBar();

  @override
  Widget build(BuildContext context) {
    final reader = FundusScope.of(context).textReader;
    final ink = _foreground(context, reader.profile.theme);
    final first = reader.chapterIndex == 0 && reader.volumeIndex == 0;
    final last =
        reader.chapterIndex + 1 >= reader.chapters.length &&
        reader.volumeIndex + 1 >= reader.volumes.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FundusSpace.x4,
          vertical: FundusSpace.x2,
        ),
        child: Row(
          children: [
            IconButton(
              onPressed: first ? null : reader.previousChapter,
              icon: Icon(
                FundusIcons.back,
                size: FundusIcons.sizeMd,
                color: ink,
              ),
              tooltip: 'Vorheriges Kapitel',
            ),
            // Kein Kapitelname hier: er ist oft so lang, dass er die Zeile
            // füllt und trotzdem abgeschnitten wird. Er steht oben.
            const Spacer(),
            IconButton(
              onPressed: last ? null : reader.nextChapter,
              icon: Icon(
                FundusIcons.forward,
                size: FundusIcons.sizeMd,
                color: ink,
              ),
              tooltip: 'Nächstes Kapitel',
            ),
          ],
        ),
      ),
    );
  }
}
