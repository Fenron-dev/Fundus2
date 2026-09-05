import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import '../../app/fundus_scope.dart';
import '../../data/download_controller.dart';
import '../../media/reader_controller.dart';
import '../../data/media_type.dart';
import '../../data/work_view.dart';
import '../../metadata/metadata_apply.dart';
import '../library/work_poster.dart';
import 'download_choice_sheet.dart';
import 'metadata_dialog.dart';
import 'metadata_editor.dart';

/// One work detail screen for every media type.
///
/// A hero plus building blocks — list, key-value, notes, devices — filled
/// differently per type. A new media type is a field and tab definition; if it
/// needed a new screen, the abstraction would be wrong.
///
/// The page is one scroll, not two. It used to be a fixed header with the
/// tabs' contents squeezed into whatever was left, which on a phone was a
/// header filling the screen and tab headings with nothing reachable under
/// them. Now the header scrolls away, the tab bar sticks to the top, and the
/// content below it has the whole screen to itself.
class WorkScreen extends StatelessWidget {
  const WorkScreen({super.key, required this.workId});

  final String workId;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final work = scope.library.workById(workId);
    if (work == null) {
      return const FundusEmptyState(
        title: 'Werk nicht gefunden',
        reason:
            'Es wurde seit dem Öffnen dieser Ansicht entfernt oder neu '
            'indexiert.',
      );
    }

    final tabs =
        work.mediaType?.tabs ?? const [WorkTab.files, WorkTab.properties];
    final stage = FundusStageSize.of(context);
    return DefaultTabController(
      length: tabs.length,
      child: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverToBoxAdapter(
            child: _Hero(work: work, stage: stage),
          ),
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedTabBar(tabs: tabs, tokens: context.fundus),
          ),
        ],
        body: TabBarView(
          children: [for (final tab in tabs) _TabContent(work: work, tab: tab)],
        ),
      ),
    );
  }
}

/// The head of the page: the artwork, the name, and what can be done with it.
///
/// On a phone everything stands in one column and the name gets the full
/// width — squeezed into a column beside the cover it broke into four lines
/// and was barely readable. From a tablet up the cover stands beside the
/// text, the way a shelf shows a spine.
class _Hero extends StatelessWidget {
  const _Hero({required this.work, required this.stage});

  final WorkView work;
  final FundusStageSize stage;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final narrow = stage == FundusStageSize.handset;
    final gutter = stage.gutter;

    return Stack(
      children: [
        // The work's own picture is the ground, blurred out of legibility and
        // faded into the page, so the head has depth without a second image
        // to fetch.
        Positioned.fill(
          child: Stack(
            fit: StackFit.expand,
            children: [
              WorkImage(
                work: work,
                wide: true,
                blurred: work.backdropPath == null,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(color: Color(0x66000000)),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      tokens.background.withValues(alpha: .25),
                      tokens.background.withValues(alpha: .82),
                      tokens.background,
                    ],
                    stops: const [0, .7, 1],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            gutter,
            narrow ? FundusSpace.x8 : FundusSpace.x12,
            gutter,
            FundusSpace.x8,
          ),
          child: narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: stage.posterWidth * 1.35,
                      child: _Cover(work: work),
                    ),
                    const SizedBox(height: FundusSpace.x6),
                    _Facts(work: work, stage: stage, centred: true),
                    const SizedBox(height: FundusSpace.x6),
                    _Actions(work: work, stretch: true),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: stage.posterWidth * 1.2,
                      child: _Cover(work: work),
                    ),
                    const SizedBox(width: FundusSpace.x8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Facts(work: work, stage: stage, centred: false),
                          const SizedBox(height: FundusSpace.x6),
                          _Actions(work: work, stretch: false),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.work});

  final WorkView work;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: FundusArtwork.cardRadius,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: .45),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: WorkArtwork(
      work: work,
      borderRadius: FundusArtwork.cardRadius,
      showOrigin: false,
    ),
  );
}

/// Everything the head says in words.
class _Facts extends StatelessWidget {
  const _Facts({
    required this.work,
    required this.stage,
    required this.centred,
  });

  final WorkView work;
  final FundusStageSize stage;
  final bool centred;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final summary = work.summary;
    final align = centred
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start;
    final textAlign = centred ? TextAlign.center : TextAlign.start;
    // One line of small print rather than a row of boxes: year, genre and
    // where the work lives, in the order somebody reads them.
    final meta = [
      if (summary.publishedYear != null) '${summary.publishedYear}',
      ...summary.genres.take(2),
      if (summary.fileCount > 1) '${summary.fileCount} Dateien',
    ].join(' · ');

    return Column(
      crossAxisAlignment: align,
      children: [
        Text(
          (work.mediaType?.label ?? 'Nicht zugeordnet').toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: tokens.accent,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: FundusSpace.x2),
        Text(
          work.title,
          textAlign: textAlign,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.displayLarge?.copyWith(
            fontSize: stage.titleSize,
            height: 1.12,
          ),
        ),
        if (work.subtitle.isNotEmpty) ...[
          const SizedBox(height: FundusSpace.x2),
          Text(
            work.subtitle,
            textAlign: textAlign,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(color: tokens.textMuted),
          ),
        ],
        if (meta.isNotEmpty) ...[
          const SizedBox(height: FundusSpace.x3),
          Text(
            meta,
            textAlign: textAlign,
            style: theme.textTheme.labelMedium?.copyWith(
              color: tokens.textFaint,
            ),
          ),
        ],
        const SizedBox(height: FundusSpace.x3),
        FundusOriginMark(work.origin, showLabel: true),
        if (work.hasProgress) ...[
          const SizedBox(height: FundusSpace.x4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: FundusProgress(
              fraction: work.progressFraction!,
              label: work.progressLabel,
              finished: work.finished,
            ),
          ),
        ],
        if (summary.description case final description?
            when description.trim().isNotEmpty) ...[
          const SizedBox(height: FundusSpace.x4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Text(
              description,
              textAlign: textAlign,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.textMuted,
              ),
            ),
          ),
        ],
        if (summary.tags.isNotEmpty) ...[
          const SizedBox(height: FundusSpace.x4),
          Wrap(
            spacing: FundusSpace.x2,
            runSpacing: FundusSpace.x2,
            alignment: centred ? WrapAlignment.center : WrapAlignment.start,
            children: [for (final tag in summary.tags.take(5)) FundusTag(tag)],
          ),
        ],
      ],
    );
  }
}

/// What can be done with the work, in one place.
class _Actions extends StatelessWidget {
  const _Actions({required this.work, required this.stretch});

  final WorkView work;

  /// A phone gives the one obvious action the whole width; a desktop puts
  /// the buttons in a row.
  final bool stretch;

  @override
  Widget build(BuildContext context) {
    final reads = ReaderController.handles(work);
    final primary = FilledButton.icon(
      // Only what can be reached offers to play; everything else says why,
      // rather than doing nothing.
      onPressed: work.origin == FundusOrigin.unreachable
          ? null
          : () => FundusScope.of(context).play(work),
      // Ein Abspielpfeil auf einem Manga verspricht das Falsche; gelesen
      // wird, nicht abgespielt.
      icon: Icon(
        reads ? FundusIcons.manga : FundusIcons.play,
        size: FundusIcons.sizeSm,
      ),
      label: Text(
        reads
            ? (work.hasProgress ? 'Weiterlesen' : 'Lesen')
            : (work.hasProgress ? 'Fortsetzen' : 'Öffnen'),
      ),
    );

    if (!stretch) {
      return Wrap(
        spacing: FundusSpace.x3,
        runSpacing: FundusSpace.x3,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          primary,
          _OfflineButton(work: work),
          _MetadataButtons(work: work),
        ],
      );
    }

    return Column(
      children: [
        SizedBox(width: double.infinity, child: primary),
        const SizedBox(height: FundusSpace.x3),
        Wrap(
          spacing: FundusSpace.x3,
          runSpacing: FundusSpace.x3,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _OfflineButton(work: work),
            _MetadataButtons(work: work),
          ],
        ),
      ],
    );
  }
}

/// The tab bar, stuck to the top once the head has scrolled past it.
class _PinnedTabBar extends SliverPersistentHeaderDelegate {
  _PinnedTabBar({required this.tabs, required this.tokens});

  final List<WorkTab> tabs;
  final FundusTokens tokens;

  static const _height = 46.0;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Container(
    height: _height,
    color: tokens.background,
    alignment: Alignment.centerLeft,
    child: _TabBar(tabs: tabs),
  );

  @override
  bool shouldRebuild(_PinnedTabBar old) =>
      old.tabs != tabs || old.tokens != tokens;
}

/// Fetching a work's details, and correcting them by hand.
///
/// Both sit here rather than in a menu somewhere: a work with the wrong title
/// or no picture is looked at on its own page, and that is where somebody
/// wants to do something about it. A mirrored work belongs to the machine
/// that holds it and is not editable from here.
class _MetadataButtons extends StatefulWidget {
  const _MetadataButtons({required this.work});

  final WorkView work;

  @override
  State<_MetadataButtons> createState() => _MetadataButtonsState();
}

class _MetadataButtonsState extends State<_MetadataButtons> {
  bool _busy = false;

  Future<void> _match(FundusScopeState scope) async {
    final vault = scope.library.library;
    if (vault == null) return;
    final candidate = await showMetadataDialog(
      context,
      work: widget.work,
      settings: scope.settings,
    );
    if (candidate == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await applyMetadata(
        library: vault,
        work: widget.work,
        candidate: candidate,
      );
      scope.library.refreshWork(widget.work.id);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            result.coverFailed
                ? '„${result.title}" übernommen — das Titelbild kam nicht an.'
                : result.coverFetched && result.backdropFetched
                ? '„${result.title}" übernommen, mit Titelbild und Breitbild.'
                : result.backdropFetched
                ? '„${result.title}" übernommen, mit Breitbild.'
                : result.coverFetched
                ? '„${result.title}" übernommen, mit Titelbild.'
                : '„${result.title}" übernommen.',
          ),
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('Nicht übernommen: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(FundusScopeState scope) async {
    final vault = scope.library.library;
    if (vault == null) return;
    final saved = await showMetadataEditor(
      context,
      library: vault,
      work: widget.work,
    );
    if (saved) scope.library.refreshWork(widget.work.id);
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final vault = scope.library.library;
    // A mirrored work is an index of something on another machine; its
    // details are that machine's to change.
    if (vault == null ||
        vault.isReadOnly ||
        widget.work.summary.sourceId != 'local') {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: FundusSpace.x3,
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : () => unawaited(_match(scope)),
          icon: Icon(FundusIcons.search, size: FundusIcons.sizeSm),
          label: Text(_busy ? 'Wird übernommen …' : 'Details abgleichen'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => unawaited(_edit(scope)),
          icon: Icon(FundusIcons.edit, size: FundusIcons.sizeSm),
          label: const Text('Bearbeiten'),
        ),
      ],
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.tabs});

  final List<WorkTab> tabs;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.divider)),
      ),
      child: TabBar(
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        indicatorColor: tokens.accent,
        dividerColor: Colors.transparent,
        labelColor: tokens.text,
        unselectedLabelColor: tokens.textMuted,
        labelStyle: Theme.of(context).textTheme.bodyMedium,
        tabs: [for (final tab in tabs) Tab(text: tab.label, height: 40)],
      ),
    );
  }
}

/// The page margin for a tab's content.
///
/// The head and the content below it line up on the same gutter, and a phone
/// gets a narrower one than a desktop window.
EdgeInsets _contentPadding(BuildContext context) {
  final gutter = FundusStageSize.of(context).gutter;
  return EdgeInsets.fromLTRB(gutter, FundusSpace.x6, gutter, FundusSpace.x12);
}

class _TabContent extends StatelessWidget {
  const _TabContent({required this.work, required this.tab});

  final WorkView work;
  final WorkTab tab;

  @override
  Widget build(BuildContext context) {
    return switch (tab) {
      WorkTab.properties => _Properties(work: work),
      WorkTab.notes => _Notes(work: work),
      WorkTab.devices => _Devices(work: work),
      WorkTab.files ||
      WorkTab.chapters ||
      WorkTab.episodes ||
      WorkTab.volumes => _Files(work: work),
      WorkTab.cast => _People(work: work),
      WorkTab.related || WorkTab.extras => const FundusEmptyState(
        title: 'Nichts verknüpft',
        reason:
            'Verwandte Werke entstehen aus Reihe, Person und Sammlung — für '
            'dieses Werk ist noch keine dieser Verbindungen erfasst.',
      ),
    };
  }
}

class _Properties extends StatelessWidget {
  const _Properties({required this.work});

  final WorkView work;

  @override
  Widget build(BuildContext context) {
    final summary = work.summary;
    final entries = <(String, String)>[
      ('Titel', summary.title),
      if (summary.authors.isNotEmpty) ('Urheber', summary.authors.join(', ')),
      if (summary.narrators.isNotEmpty)
        ('Sprecher', summary.narrators.join(', ')),
      if (summary.series != null) ('Reihe', summary.series!),
      if (summary.publisher != null) ('Verlag', summary.publisher!),
      if (summary.publishedYear != null) ('Jahr', '${summary.publishedYear}'),
      if (summary.language != null) ('Sprache', summary.language!),
      if (summary.genres.isNotEmpty) ('Genres', summary.genres.join(', ')),
      ('Medientyp', work.mediaType?.label ?? 'Nicht zugeordnet'),
      ('Technischer Grundtyp', summary.kind),
      ('Herkunft', work.origin.label),
      ('Dateien', '${summary.fileCount}'),
      ('Aufgenommen', _formatDate(summary.addedAt)),
    ];

    final theme = Theme.of(context);
    final tokens = context.fundus;
    final description = summary.description?.trim();

    // Erst die Handlung, dann die Angaben. Eine Tabelle als Erstes zu zeigen
    // ist die Ordnung eines Karteikastens, nicht die einer Mediathek — der
    // Kopf zeigt nur die ersten Zeilen, hier steht der ganze Text.
    return ListView(
      padding: _contentPadding(context),
      children: [
        if (description != null && description.isNotEmpty) ...[
          Text('HANDLUNG', style: theme.textTheme.labelSmall),
          const SizedBox(height: FundusSpace.x3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Text(
              description,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ),
          const SizedBox(height: FundusSpace.x8),
        ],
        Text('ANGABEN', style: theme.textTheme.labelSmall),
        const SizedBox(height: FundusSpace.x3),
        for (final entry in entries) _KeyValueRow(entry.$1, entry.$2),
        if (summary.tags.isNotEmpty) ...[
          const SizedBox(height: FundusSpace.x6),
          Text(
            'SCHLAGWORTE',
            style: theme.textTheme.labelSmall?.copyWith(
              color: tokens.textMuted,
            ),
          ),
          const SizedBox(height: FundusSpace.x3),
          Wrap(
            spacing: FundusSpace.x2,
            runSpacing: FundusSpace.x2,
            children: [for (final tag in summary.tags) FundusTag(tag)],
          ),
        ],
      ],
    );
  }

  static String _formatDate(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}.'
      '${value.month.toString().padLeft(2, '0')}.${value.year}';
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall?.copyWith(
      color: tokens.textFaint,
    );
    // Auf dem Handy steht die Bezeichnung über dem Wert: eine feste Spalte
    // von 190 Pixeln lässt daneben nichts übrig, was sich lesen ließe.
    if (FundusStageSize.of(context) == FundusStageSize.handset) {
      return Padding(
        padding: const EdgeInsets.only(bottom: FundusSpace.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: caption),
            const SizedBox(height: FundusSpace.x1),
            Text(value, style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: FundusSpace.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 190, child: Text(label, style: caption)),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// The files a work is made of, as a list one can actually use.
///
/// It was a read-only inventory: numbers, names, lengths, and no way to start
/// episode seven or to say that episode three has been seen. Both are the
/// ordinary things somebody wants from a list of episodes, so both are here —
/// and a series with several seasons picks one rather than showing ninety
/// entries in a row.
class _Files extends StatefulWidget {
  const _Files({required this.work});

  final WorkView work;

  @override
  State<_Files> createState() => _FilesState();
}

class _FilesState extends State<_Files> {
  List<LibraryPlaybackTrack>? _tracks;
  Set<String> _finished = const {};
  String? _failure;

  /// Null is „alle", which is also what a work without seasons shows.
  int? _season;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reading the scope needs an inherited widget, which is not available in
    // initState.
    _load();
  }

  void _load() {
    final library = FundusScope.of(context).library.library;
    if (library == null) return;
    try {
      final tracks = library.playbackTracks(widget.work.id);
      final finished = library.finishedFiles(widget.work.id);
      setState(() {
        _tracks = tracks;
        _finished = finished;
        _season ??= _seasons(tracks).firstOrNull;
      });
    } on Object catch (failure) {
      setState(() => _failure = failure.toString());
    }
  }

  /// The seasons this work has, in order. Empty where nothing says.
  List<int> _seasons(List<LibraryPlaybackTrack> tracks) {
    final seasons = <int>{};
    for (final track in tracks) {
      final number = episodeNumberOf(track.relativePath).season;
      if (number != null) seasons.add(number);
    }
    return seasons.toList()..sort();
  }

  Future<void> _toggleFinished(LibraryPlaybackTrack track) async {
    final scope = FundusScope.of(context);
    final library = scope.library.library;
    if (library == null || library.isReadOnly) return;
    final done = _finished.contains(track.fileId);
    library.setFileFinished(
      workId: widget.work.id,
      fileId: track.fileId,
      finished: !done,
    );
    setState(() {
      _finished = {
        for (final id in _finished)
          if (id != track.fileId) id,
        if (!done) track.fileId,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tracks = _tracks;
    if (_failure != null) {
      return FundusEmptyState(
        title: 'Dateien nicht lesbar',
        reason: _failure!,
        icon: FundusIcons.warning,
      );
    }
    if (tracks == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tracks.isEmpty) {
      return const FundusEmptyState(
        title: 'Keine Inhaltsdateien',
        reason:
            'Zu diesem Werk sind keine abspielbaren oder lesbaren Dateien '
            'erfasst. Ein erneuter Scan holt sie, falls sie da sind.',
      );
    }

    final seasons = _seasons(tracks);
    final shown = seasons.length < 2
        ? tracks
        : [
            for (final track in tracks)
              if (episodeNumberOf(track.relativePath).season == _season) track,
          ];
    final gutter = FundusStageSize.of(context).gutter;

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: FundusSpace.x12),
      itemCount: shown.length + (seasons.length < 2 ? 0 : 1),
      itemBuilder: (context, index) {
        if (seasons.length >= 2) {
          if (index == 0) {
            return _SeasonBar(
              seasons: seasons,
              selected: _season ?? seasons.first,
              count: shown.length,
              onSelect: (value) => setState(() => _season = value),
            );
          }
          index -= 1;
        }
        final track = shown[index];
        final number = episodeNumberOf(track.relativePath);
        return _EpisodeRow(
          track: track,
          position: number.episode ?? tracks.indexOf(track) + 1,
          gutter: gutter,
          finished: _finished.contains(track.fileId),
          onPlay: () =>
              unawaited(scope.play(widget.work, startAt: track.fileId)),
          onToggle: () => unawaited(_toggleFinished(track)),
        );
      },
    );
  }
}

/// Which season is on show.
class _SeasonBar extends StatelessWidget {
  const _SeasonBar({
    required this.seasons,
    required this.selected,
    required this.count,
    required this.onSelect,
  });

  final List<int> seasons;
  final int selected;
  final int count;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final gutter = FundusStageSize.of(context).gutter;
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, FundusSpace.x4, gutter, 0),
      child: Row(
        children: [
          DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: selected,
              borderRadius: FundusRadius.mdAll,
              items: [
                for (final season in seasons)
                  DropdownMenuItem(
                    value: season,
                    child: Text('Staffel $season'),
                  ),
              ],
              onChanged: (value) {
                if (value != null) onSelect(value);
              },
            ),
          ),
          const SizedBox(width: FundusSpace.x4),
          Text(
            '$count Folgen',
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
          ),
        ],
      ),
    );
  }
}

/// One episode: tap to start it, tick it off, see how long it is.
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.track,
    required this.position,
    required this.gutter,
    required this.finished,
    required this.onPlay,
    required this.onToggle,
  });

  final LibraryPlaybackTrack track;
  final int position;
  final double gutter;
  final bool finished;
  final VoidCallback onPlay;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final theme = Theme.of(context);
    return InkWell(
      onTap: onPlay,
      hoverColor: tokens.hover,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: gutter,
          vertical: FundusSpace.x3,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.divider)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 34,
              child: Text(
                '$position',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: tokens.textFaint,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: finished ? tokens.textMuted : tokens.text,
                    ),
                  ),
                  if (track.duration != null || finished)
                    Text(
                      [
                        if (track.duration case final length?)
                          _formatDuration(length),
                        if (finished) 'gesehen',
                      ].join(' · '),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: tokens.textFaint,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              onPressed: onToggle,
              tooltip: finished
                  ? 'Als ungesehen markieren'
                  : 'Als gesehen markieren',
              icon: Icon(
                finished ? FundusIcons.finished : FundusIcons.unfinished,
                size: FundusIcons.sizeMd,
                color: finished ? tokens.accent : tokens.textFaint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(Duration value) {
  final hours = value.inHours;
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

class _Notes extends StatelessWidget {
  const _Notes({required this.work});

  final WorkView work;

  @override
  Widget build(BuildContext context) {
    final library = FundusScope.of(context).library.library;
    if (library == null) return const SizedBox.shrink();
    final annotations = library.loadAnnotations(work.id);
    final tokens = context.fundus;

    if (annotations.notes.isEmpty && annotations.bookmarks.isEmpty) {
      return const FundusEmptyState(
        title: 'Noch keine Notizen',
        reason:
            'Notizen und Lesezeichen gehören dem Werk und liegen als Klartext '
            'neben den Dateien — sie überleben einen Index-Neuaufbau.',
        icon: null,
      );
    }

    return ListView(
      padding: _contentPadding(context),
      children: [
        if (annotations.bookmarks.isNotEmpty) ...[
          Text('LESEZEICHEN', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: FundusSpace.x3),
          for (final bookmark in annotations.bookmarks)
            Padding(
              padding: const EdgeInsets.only(bottom: FundusSpace.x2),
              child: Row(
                children: [
                  FundusTag(
                    bookmark.displayPosition,
                    tone: FundusTagTone.accent,
                  ),
                  const SizedBox(width: FundusSpace.x3),
                  Expanded(
                    child: Text(
                      bookmark.label ?? bookmark.note ?? 'Ohne Beschriftung',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: FundusSpace.x8),
        ],
        if (annotations.notes.isNotEmpty) ...[
          Text('NOTIZEN', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: FundusSpace.x3),
          for (final note in annotations.notes)
            Container(
              margin: const EdgeInsets.only(bottom: FundusSpace.x3),
              padding: const EdgeInsets.all(FundusSpace.x4),
              decoration: BoxDecoration(
                color: tokens.surface,
                borderRadius: FundusRadius.mdAll,
                border: Border.fromBorderSide(
                  BorderSide(color: tokens.divider),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _formatDate(note.createdAt),
                    style: Theme.of(
                      context,
                    ).textTheme.labelMedium?.copyWith(color: tokens.textFaint),
                  ),
                  const SizedBox(height: FundusSpace.x2),
                  Text(
                    note.markdown,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  static String _formatDate(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}.'
      '${value.month.toString().padLeft(2, '0')}.${value.year}';
}

class _People extends StatelessWidget {
  const _People({required this.work});

  final WorkView work;

  @override
  Widget build(BuildContext context) {
    final people = <(String, String)>[
      for (final author in work.summary.authors) (author, 'Urheber'),
      for (final narrator in work.summary.narrators) (narrator, 'Sprecher'),
    ];
    if (people.isEmpty) {
      return const FundusEmptyState(
        title: 'Keine Personen erfasst',
        reason:
            'Personen entstehen beim Import aus Metadaten; von Hand ergänzte '
            'Angaben bleiben bei späteren Scans geschützt.',
      );
    }
    return ListView(
      padding: _contentPadding(context),
      children: [
        for (final person in people)
          ListTile(
            leading: Icon(FundusIcons.person, size: FundusIcons.sizeLg),
            title: Text(person.$1),
            subtitle: Text(person.$2),
          ),
      ],
    );
  }
}

class _Devices extends StatefulWidget {
  const _Devices({required this.work});

  final WorkView work;

  @override
  State<_Devices> createState() => _DevicesState();
}

class _DevicesState extends State<_Devices> {
  Future<List<DeviceProfile>>? _profiles;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Created once: a future built inside build() restarts on every rebuild.
    _profiles ??= FundusScope.of(context).library.library?.listDeviceProfiles();
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final profiles = _profiles;
    if (profiles == null) return const SizedBox.shrink();

    return FutureBuilder<List<DeviceProfile>>(
      future: profiles,
      builder: (context, snapshot) {
        final profiles = snapshot.data ?? const <DeviceProfile>[];
        if (profiles.isEmpty) {
          return const FundusEmptyState(
            title: 'Nur dieses Gerät',
            reason:
                'Sobald ein zweites Gerät dieselbe Bibliothek öffnet, steht '
                'hier dessen Stand für dieses Werk.',
            icon: null,
          );
        }
        return ListView(
          padding: _contentPadding(context),
          children: [
            for (final profile in profiles)
              ListTile(
                leading: Icon(FundusIcons.devices, size: FundusIcons.sizeLg),
                title: Text(profile.displayName),
                subtitle: Text(
                  profile.key == scope.settings.deviceKey
                      ? 'Dieses Gerät'
                      : profile.platform.isEmpty
                      ? 'Anderes Gerät'
                      : profile.platform,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Taking this work along, or giving it back to the network.
///
/// Only offered where it means something: a work that is already on this
/// disk has nothing to download, and a work on a machine this device cannot
/// reach has nothing to download it from.
class _OfflineButton extends StatelessWidget {
  const _OfflineButton({required this.work});

  final WorkView work;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final downloads = scope.downloads;
    final job = downloads.jobFor(work.id);

    if (downloads.isSecured(work.id)) {
      return OutlinedButton.icon(
        onPressed: () => downloads.remove(work.id),
        icon: Icon(FundusIcons.originOffline, size: FundusIcons.sizeSm),
        label: const Text('Offline · entfernen'),
      );
    }

    if (job != null) {
      return switch (job.state) {
        DownloadState.failed => OutlinedButton.icon(
          onPressed: () => downloads.download(work),
          icon: Icon(FundusIcons.warning, size: FundusIcons.sizeSm),
          label: const Text('Erneut versuchen'),
        ),
        DownloadState.done => const SizedBox.shrink(),
        _ => OutlinedButton.icon(
          onPressed: job.state == DownloadState.queued
              ? () => downloads.cancel(work.id)
              : null,
          icon: SizedBox(
            width: FundusIcons.sizeSm,
            height: FundusIcons.sizeSm,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: job.progress == 0 ? null : job.progress,
            ),
          ),
          label: Text('${(job.progress * 100).round()} %'),
        ),
      };
    }

    if (!downloads.canDownload(work)) return const SizedBox.shrink();

    return OutlinedButton.icon(
      onPressed: () => unawaited(_take(context, scope, work)),
      icon: Icon(FundusIcons.downloads, size: FundusIcons.sizeSm),
      label: const Text('Mitnehmen'),
    );
  }

  /// A film comes along whole; a manga is asked about first.
  ///
  /// „Alles" on four hundred chapters is rarely what somebody means, and it
  /// is the one download nobody can take back halfway.
  static Future<void> _take(
    BuildContext context,
    FundusScopeState scope,
    WorkView work,
  ) async {
    final vault = scope.library.library;
    if (vault == null) return;
    final tracks = vault.playbackTracks(work.id);
    if (tracks.length < 4) {
      await scope.downloads.download(work);
      return;
    }
    final here = {
      for (final file in vault.contentFiles(work.id))
        if (file.availability == 'offline_copy') file.fileId,
    };
    final saved = vault.loadProgress(work.id);
    final startAt = saved?.fileId == null
        ? 0
        : tracks.indexWhere((track) => track.fileId == saved!.fileId);
    if (!context.mounted) return;
    final chosen = await showDownloadChoice(
      context,
      title: work.title,
      tracks: tracks,
      alreadyHere: here,
      startAt: startAt < 0 ? 0 : startAt,
    );
    if (chosen == null || chosen.isEmpty) return;
    await scope.downloads.download(work, only: chosen);
  }
}
