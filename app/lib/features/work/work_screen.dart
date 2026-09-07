import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_navigation.dart';
import '../../app/fundus_scope.dart';
import '../../data/download_controller.dart';
import '../../media/playback_controller.dart' show formatPlaybackTime;
import '../../media/reader_controller.dart';
import '../../data/media_type.dart';
import '../../data/work_filter.dart';
import '../../data/work_view.dart';
import '../../metadata/metadata_apply.dart';
import '../downloads/downloads_screen.dart' show formatBytes;
import '../library/work_poster.dart';
import '../people/person_credits.dart';
import '../people/person_screen.dart';
import '../lists/add_to_list.dart';
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Cover(work: work),
                          const SizedBox(height: FundusSpace.x4),
                          _Storage(work: work, centred: false),
                        ],
                      ),
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
/// Woher das Werk kommt, wie groß es ist und wo es liegt.
///
/// Die Fragen, die man sich vor dem Löschen stellt — und die einzigen
/// Angaben auf dieser Seite, die nicht vom Werk, sondern von der Datei
/// handeln. Deshalb stehen sie klein und unter dem Bild.
class _Storage extends StatelessWidget {
  const _Storage({required this.work, required this.centred});

  final WorkView work;
  final bool centred;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final library = scope.library.library;
    if (library == null) return const SizedBox.shrink();

    final storage = library.workStorage(work.id);
    final source = scope.library.sources
        .where((entry) => entry.id == work.summary.sourceId)
        .firstOrNull;
    final rows = <(String, String)>[
      if (source != null) ('Quelle', source.displayName),
      if (_resolution(storage.height) case final resolution?)
        ('Auflösung', resolution),
      if (storage.bytes > 0) ('Größe', formatBytes(storage.bytes)),
    ];
    if (rows.isEmpty && work.summary.sourcePath.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: centred
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.stretch,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              mainAxisSize: centred ? MainAxisSize.min : MainAxisSize.max,
              children: [
                Text(
                  row.$1,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: tokens.textFaint,
                  ),
                ),
                const SizedBox(width: FundusSpace.x3),
                Expanded(
                  flex: centred ? 0 : 1,
                  child: Text(
                    row.$2,
                    textAlign: centred ? TextAlign.start : TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        if (work.summary.sourcePath.isNotEmpty) ...[
          const SizedBox(height: FundusSpace.x2),
          Text(
            work.summary.sourcePath,
            textAlign: centred ? TextAlign.center : TextAlign.start,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: tokens.textFaint,
            ),
          ),
        ],
      ],
    );
  }

  /// „2160p" sagt mehr als „3840 × 2160", und die Höhe genügt dafür.
  static String? _resolution(int? height) {
    if (height == null || height <= 0) return null;
    return '${height}p';
  }
}

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
      ?summary.publishedYear?.toString(),
      if (summary.series case final series?
          when series.trim().isNotEmpty && series != work.title)
        summary.seriesSequence == null
            ? series
            : '$series · Band ${_band(summary.seriesSequence!)}',
      ...summary.genres.take(3),
      ?_upper(summary.language),
      ?_trimmed(summary.publisher),
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
        // Genres und Schlagwörter stehen hier zusammen, weil sie hier
        // dasselbe sind: eine Frage danach, was es sonst noch damit gibt.
        if (WorkFilter.labelsOf(work).isNotEmpty) ...[
          const SizedBox(height: FundusSpace.x4),
          Wrap(
            spacing: FundusSpace.x2,
            runSpacing: FundusSpace.x2,
            alignment: centred ? WrapAlignment.center : WrapAlignment.start,
            children: [
              for (final label in WorkFilter.labelsOf(work).take(5))
                FundusTag(
                  label,
                  onTap: () => FundusScope.of(context).showLabel(label),
                ),
            ],
          ),
        ],
        // Auf dem Handy nur, wenn es etwas zu zeigen gibt: dort zählt jede
        // Zeile im Kopf gegen die Liste darunter.
        if (work.summary.externalIds.isNotEmpty || !centred) ...[
          const SizedBox(height: FundusSpace.x4),
          _External(work: work, centred: centred),
        ],
      ],
    );
  }

  /// Ein Wert ohne Ränder, oder gar nichts.
  static String? _trimmed(String? value) =>
      value == null || value.trim().isEmpty ? null : value.trim();

  /// Eine Sprache in Großbuchstaben, oder gar nichts.
  static String? _upper(String? value) =>
      value == null || value.trim().isEmpty ? null : value.toUpperCase();

  /// „Band 3" statt „Band 3.0".
  static String _band(double value) {
    final rounded = value.round();
    return value == rounded ? '$rounded' : '$value';
  }
}

/// Wo dieses Werk außerhalb der Bibliothek geführt wird.
///
/// Eine Kennung bei einem Dienst ist keine Zierde: sie ist der Weg zurück
/// zur Quelle und die Bedingung dafür, dass ein späterer Abgleich dasselbe
/// Werk wiederfindet. Was fehlt, sagt es — und lässt sich von hier aus
/// nachholen.
class _External extends StatelessWidget {
  const _External({required this.work, required this.centred});

  final WorkView work;
  final bool centred;

  /// Die Adresse, unter der ein Dienst dieses Werk zeigt.
  static Uri? addressFor(String service, String id) => switch (service) {
    'tmdb' => Uri.parse('https://www.themoviedb.org/search?query=$id'),
    'anilist' => Uri.parse('https://anilist.co/anime/$id'),
    'openlibrary' => Uri.parse('https://openlibrary.org/works/$id'),
    'itunes' => Uri.parse('https://podcasts.apple.com/podcast/id$id'),
    'audible' || 'asin' => Uri.parse('https://www.audible.de/pd/$id'),
    'feed' => Uri.tryParse(id),
    _ => null,
  };

  static const _names = {
    'tmdb': 'TMDB',
    'anilist': 'AniList',
    'openlibrary': 'Open Library',
    'itunes': 'Apple Podcasts',
    'audible': 'Audible',
    'asin': 'ASIN',
    'feed': 'Feed',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final ids = work.summary.externalIds;
    // Die ASIN steht schon als „Audible" da, wenn beides gesetzt ist.
    final shown = {
      for (final entry in ids.entries)
        if (entry.key != 'asin' || !ids.containsKey('audible'))
          entry.key: entry.value,
    };
    final matched = _matchedAt(work);

    return Wrap(
      spacing: FundusSpace.x2,
      runSpacing: FundusSpace.x2,
      alignment: centred ? WrapAlignment.center : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'EXTERN',
          style: theme.textTheme.labelSmall?.copyWith(
            color: tokens.textFaint,
            letterSpacing: 1.2,
          ),
        ),
        if (shown.isEmpty)
          Text(
            'noch nicht verknüpft',
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.textFaint),
          ),
        for (final entry in shown.entries)
          ActionChip(
            avatar: Icon(FundusIcons.originStream, size: FundusIcons.sizeSm),
            label: Text(_names[entry.key] ?? entry.key),
            onPressed: () {
              final address = addressFor(entry.key, entry.value);
              if (address != null) unawaited(launchUrl(address));
            },
          ),
        if (matched != null)
          Text(
            'abgeglichen ${_ago(matched)}',
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.textFaint),
          ),
      ],
    );
  }

  /// Wann zuletzt ein Dienst etwas an diesem Werk geschrieben hat.
  static DateTime? _matchedAt(WorkView work) {
    DateTime? newest;
    for (final origin in work.summary.metadataOrigins.values) {
      if (origin.source != WorkMetadataSource.online) continue;
      if (newest == null || origin.updatedAt.isAfter(newest)) {
        newest = origin.updatedAt;
      }
    }
    return newest;
  }

  static String _ago(DateTime value) {
    final days = DateTime.now().difference(value).inDays;
    if (days <= 0) return 'heute';
    if (days == 1) return 'gestern';
    if (days < 31) return 'vor $days Tagen';
    final months = days ~/ 30;
    return months < 12 ? 'vor $months Monaten' : 'vor über einem Jahr';
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
      // Auch was zuletzt nicht erreichbar war, lässt sich drücken: die
      // Markierung stammt vom letzten Durchgang, und ein Netzlaufwerk, das
      // kurz weg war, ist gleich wieder da. Der Versuch entscheidet, und
      // scheitert er, sagt der Player warum — ein toter Knopf sagt nichts.
      onPressed: () => FundusScope.of(context).play(work),
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
          _FavouriteButton(work: work),
          _ListButton(work: work),
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
            _ListButton(work: work),
            _OfflineButton(work: work),
            _MoreDetailsButton(work: work),
            _MetadataButtons(work: work),
          ],
        ),
      ],
    );
  }
}

/// On a phone the desktop metadata column lives in the properties tab. Keep
/// that tab one obvious tap away so genres, tags, external sources and the
/// per-file seen controls are not mistaken for missing functionality.
class _MoreDetailsButton extends StatelessWidget {
  const _MoreDetailsButton({required this.work});

  final WorkView work;

  @override
  Widget build(BuildContext context) {
    final tabs =
        work.mediaType?.tabs ?? const [WorkTab.files, WorkTab.properties];
    final index = tabs.indexOf(WorkTab.properties);
    if (index < 0) return const SizedBox.shrink();
    return OutlinedButton.icon(
      onPressed: () => DefaultTabController.of(context).animateTo(index),
      icon: Icon(FundusIcons.note, size: FundusIcons.sizeSm),
      label: const Text('Details & Status'),
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
    final choice = await showMetadataDialog(
      context,
      work: widget.work,
      settings: scope.settings,
    );
    if (choice == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await applyMetadata(
        library: vault,
        work: widget.work,
        candidate: choice.candidate,
        fields: choice.fields,
      );
      scope.library.refreshWork(widget.work.id);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            [
              choice.linkOnly
                  ? '„${result.title}" verknüpft — nichts überschrieben.'
                  : result.coverFailed
                  ? '„${result.title}" übernommen — das Titelbild kam '
                        'nicht an.'
                  : result.coverFetched && result.backdropFetched
                  ? '„${result.title}" übernommen, mit Titelbild und '
                        'Breitbild.'
                  : result.backdropFetched
                  ? '„${result.title}" übernommen, mit Breitbild.'
                  : result.coverFetched
                  ? '„${result.title}" übernommen, mit Titelbild.'
                  : '„${result.title}" übernommen.',
              // Bei einem Podcast ist genau das die Frage, die man sich
              // stellt: hat er die Folgen wiedergefunden?
              if (result.episodesDescribed > 0)
                '${result.episodesDescribed} Folgen beschrieben.'
              else if (result.feedRead)
                'Keine Folge ließ sich einem Feed-Eintrag zuordnen.',
            ].join(' '),
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

/// Was ein Werk belegt, als Zeile für die Eigenschaften.
(String, String)? _storageRow(BuildContext context, WorkView work) {
  final library = FundusScope.of(context).library.library;
  if (library == null) return null;
  final bytes = library.workStorage(work.id).bytes;
  return bytes <= 0 ? null : ('Größe', formatBytes(bytes));
}

(String, String)? _resolutionRow(BuildContext context, WorkView work) {
  final library = FundusScope.of(context).library.library;
  final height = library?.workStorage(work.id).height;
  return height == null || height <= 0 ? null : ('Auflösung', '${height}p');
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
      // Was die Datei sagt, nicht das Werk — dieselben Angaben stehen am
      // Rechner neben dem Bild, auf dem Handy wäre dafür kein Platz.
      ?_storageRow(context, work),
      ?_resolutionRow(context, work),
      if (summary.sourcePath.isNotEmpty) ('Pfad', summary.sourcePath),
      for (final entry in summary.externalIds.entries)
        (_External._names[entry.key] ?? entry.key, entry.value),
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
        if (WorkFilter.labelsOf(work).isNotEmpty) ...[
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
            children: [
              for (final label in WorkFilter.labelsOf(work))
                FundusTag(
                  label,
                  onTap: () => FundusScope.of(context).showLabel(label),
                ),
            ],
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
  Map<String, FileDetail> _details = const {};

  /// Wo jede Folge steht — die Zeile sagt es, ohne dass man sie öffnet.
  Map<String, ({double position, double? total, DateTime updatedAt})>
  _positions = const {};

  /// Die Marken innerhalb einer Folge, erst gelesen, wenn jemand sie
  /// aufklappt: dafür muss die Datei angefasst werden.
  final _chapters = <String, List<LibraryPlaybackChapter>>{};
  final _expanded = <String>{};
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
      final details = library.fileDetails(widget.work.id);
      final positions = library.filePositions(widget.work.id);
      setState(() {
        _tracks = tracks;
        _finished = finished;
        _details = details;
        _positions = positions;
        _season ??= _seasons(tracks).firstOrNull;
      });
      _fillMissingTexts(library, tracks, details);
    } on Object catch (failure) {
      setState(() => _failure = failure.toString());
    }
  }

  /// Holt die Texte, die in den Dateien selbst stehen.
  ///
  /// Ein Feed kennt nur seine eigene Sendung, und in einem Ordner liegen oft
  /// mehrere. Der Text steht aber ohnehin in den Tags — also wird er hier
  /// nachgelesen, sobald jemand die Folgenliste ansieht, und nur für die
  /// Folgen, zu denen noch nichts dasteht.
  void _fillMissingTexts(
    FundusLibrary library,
    List<LibraryPlaybackTrack> tracks,
    Map<String, FileDetail> details,
  ) {
    if (!(widget.work.mediaType?.hasChapterImages ?? false)) return;
    if (library.isReadOnly) return;
    final missing = tracks.any(
      (track) => !track.isRemote && details[track.fileId]?.description == null,
    );
    if (!missing) return;
    unawaited(() async {
      final added = await describeFromTags(
        library: library,
        workId: widget.work.id,
      );
      if (added == 0 || !mounted) return;
      setState(() => _details = library.fileDetails(widget.work.id));
    }());
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

  /// Klappt eine Folge auf und liest dabei ihre Kapitelmarken.
  ///
  /// Erst hier, nicht beim Öffnen der Liste: die Marken stehen in der Datei,
  /// und dreißig Dateien anzufassen, um eine Liste zu zeigen, wäre eine
  /// Sekunde Warten für nichts.
  Future<void> _toggleDetails(LibraryPlaybackTrack track) async {
    final open = _expanded.contains(track.fileId);
    setState(() {
      if (open) {
        _expanded.remove(track.fileId);
      } else {
        _expanded.add(track.fileId);
      }
    });
    if (open || _chapters.containsKey(track.fileId)) return;
    final library = FundusScope.of(context).library.library;
    if (library == null || track.isRemote) return;
    try {
      final marks = await library.trackChapters(widget.work.id, track.fileId);
      if (!mounted) return;
      setState(() => _chapters[track.fileId] = marks);
    } on Object {
      if (mounted) setState(() => _chapters[track.fileId] = const []);
    }
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
    // Auch eine einzelne Staffel wird benannt: „Staffel 1 · 12 Folgen" ist
    // eine Auskunft, kein Bedienelement, und sie fehlte.
    final shown = seasons.length < 2
        ? tracks
        : [
            for (final track in tracks)
              if (episodeNumberOf(track.relativePath).season == _season) track,
          ];
    final gutter = FundusStageSize.of(context).gutter;

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: FundusSpace.x12),
      itemCount: shown.length + (seasons.isEmpty ? 0 : 1),
      itemBuilder: (context, index) {
        if (seasons.isNotEmpty) {
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
        final detail = _details[track.fileId];
        return _EpisodeRow(
          track: track,
          position: number.episode ?? tracks.indexOf(track) + 1,
          gutter: gutter,
          finished: _finished.contains(track.fileId),
          detail: detail,
          standing: _positions[track.fileId],
          chapters: _chapters[track.fileId],
          // Bei einer Sendung mit eigenem Innenleben führt ein Tipp auf die
          // Zeile zu dem, was drinsteht — gestartet wird mit dem Knopf davor.
          detailsFirst: widget.work.mediaType?.hasChapterImages ?? false,
          expanded: _expanded.contains(track.fileId),
          onExpand: () => unawaited(_toggleDetails(track)),
          onPlayChapter: (mark) => unawaited(
            scope.play(widget.work, startAt: track.fileId, at: mark.position),
          ),
          onPlay: () =>
              unawaited(scope.play(widget.work, startAt: track.fileId)),
          onToggle: () => unawaited(_toggleFinished(track)),
          onAddToList: () => unawaited(
            showAddToList(
              context,
              workId: widget.work.id,
              fileId: track.fileId,
              label: track.title,
            ),
          ),
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

/// Eine Folge: starten, nachlesen, abhaken.
///
/// Der Abspielknopf steht vorn. Ein Tipp auf die Zeile führt bei einer
/// Sendung mit eigenem Innenleben nicht zum Start, sondern zu dem, was
/// drinsteht — Text, Datum und die Marken innerhalb der Folge.
class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.track,
    required this.position,
    required this.gutter,
    required this.finished,
    required this.detail,
    required this.standing,
    required this.chapters,
    required this.detailsFirst,
    required this.expanded,
    required this.onExpand,
    required this.onPlay,
    required this.onPlayChapter,
    required this.onToggle,
    required this.onAddToList,
  });

  final LibraryPlaybackTrack track;
  final int position;
  final double gutter;
  final bool finished;

  /// Was der Feed — oder die Datei selbst — über diese Folge sagt.
  final FileDetail? detail;

  /// Wo diese Folge steht, wenn sie angefangen ist.
  final ({double position, double? total, DateTime updatedAt})? standing;

  /// Die Marken innerhalb der Folge, sobald sie gelesen sind. Null heißt
  /// „noch nicht nachgesehen", leer heißt „es gibt keine".
  final List<LibraryPlaybackChapter>? chapters;

  /// Ob ein Tipp auf die Zeile die Folge zeigt, statt sie zu starten.
  final bool detailsFirst;
  final bool expanded;
  final VoidCallback onExpand;
  final VoidCallback onPlay;
  final void Function(LibraryPlaybackChapter chapter) onPlayChapter;
  final VoidCallback onToggle;

  /// Eine einzelne Folge in eine Liste legen — ein Album ist ein Werk mit
  /// einem Dutzend Titeln, und gemeint ist der Titel.
  final VoidCallback onAddToList;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final theme = Theme.of(context);
    final left = _remaining;

    return InkWell(
      onTap: detailsFirst ? onExpand : onPlay,
      hoverColor: tokens.hover,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: gutter,
          vertical: FundusSpace.x3,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.divider)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 26,
                  child: Text(
                    '$position',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: tokens.textFaint,
                    ),
                  ),
                ),
                // Gestartet wird mit dem Knopf; alles andere an der Zeile ist
                // Nachlesen.
                IconButton(
                  onPressed: onPlay,
                  tooltip: 'Abspielen',
                  icon: Icon(
                    FundusIcons.play,
                    size: FundusIcons.sizeMd,
                    color: finished ? tokens.textFaint : tokens.accent,
                  ),
                ),
                const SizedBox(width: FundusSpace.x2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        detail?.title ?? track.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: finished ? tokens.textMuted : tokens.text,
                        ),
                      ),
                      Text(
                        [
                          if (detail?.publishedAt case final date?)
                            _formatDate(date),
                          if (left != null)
                            'noch ${_formatDuration(left)}'
                          else if (track.duration case final length?)
                            _formatDuration(length),
                          // „gesehen" für alles mit Bild, „gehört" für eine
                          // Sendung, die man hört.
                          if (finished) (detailsFirst ? 'gehört' : 'gesehen'),
                        ].join(' · '),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: tokens.textFaint,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onExpand,
                  tooltip: expanded ? 'Weniger' : 'Worum es geht',
                  icon: Icon(
                    expanded ? FundusIcons.collapse : FundusIcons.expand,
                    size: FundusIcons.sizeMd,
                    color: tokens.textFaint,
                  ),
                ),
                IconButton(
                  onPressed: onAddToList,
                  tooltip: 'Zur Liste hinzufügen',
                  icon: Icon(
                    FundusIcons.lists,
                    size: FundusIcons.sizeMd,
                    color: tokens.textFaint,
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
            // Eine angefangene Folge zeigt, wie weit sie ist.
            if (_progress case final share?)
              Padding(
                padding: const EdgeInsets.only(
                  left: FundusSpace.x8,
                  top: FundusSpace.x2,
                  right: FundusSpace.x4,
                ),
                child: ClipRRect(
                  borderRadius: FundusRadius.smAll,
                  child: LinearProgressIndicator(
                    value: share,
                    minHeight: 3,
                    backgroundColor: tokens.divider,
                  ),
                ),
              ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.only(
                  left: FundusSpace.x8,
                  top: FundusSpace.x3,
                  right: FundusSpace.x4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (detail?.description case final text?)
                      Text(
                        text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: tokens.textMuted,
                          height: 1.45,
                        ),
                      )
                    else
                      Text(
                        'Zu dieser Folge liegt kein Text vor.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: tokens.textFaint,
                        ),
                      ),
                    if (chapters case final marks?)
                      if (marks.isNotEmpty) ...[
                        const SizedBox(height: FundusSpace.x3),
                        Text(
                          'KAPITEL · ${marks.length}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: tokens.textFaint,
                          ),
                        ),
                        for (final mark in marks)
                          _ChapterLine(
                            chapter: mark,
                            onTap: () => onPlayChapter(mark),
                          ),
                      ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Wie viel von der Folge noch aussteht.
  Duration? get _remaining {
    final saved = standing;
    if (saved == null) return null;
    final total = saved.total ?? _lengthInSeconds;
    if (total == null || total <= 0) return null;
    final left = total - saved.position;
    return left <= 1 ? null : Duration(seconds: left.round());
  }

  double? get _lengthInSeconds {
    final length = track.duration;
    return length == null ? null : length.inMilliseconds / 1000;
  }

  /// Wie weit die Folge ist, als Anteil.
  double? get _progress {
    final saved = standing;
    if (saved == null || saved.position <= 0) return null;
    final total = saved.total ?? _lengthInSeconds;
    if (total == null || total <= 0) return null;
    return (saved.position / total).clamp(0.0, 1.0);
  }
}

/// Eine Kapitelmarke innerhalb einer Folge, mit ihrem Bild, wo eines da ist.
class _ChapterLine extends StatelessWidget {
  const _ChapterLine({required this.chapter, required this.onTap});

  final LibraryPlaybackChapter chapter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.fundus;
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: FundusRadius.smAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: FundusSpace.x2),
        child: Row(
          children: [
            if (chapter.imagePath case final path?)
              Padding(
                padding: const EdgeInsets.only(right: FundusSpace.x3),
                child: ClipRRect(
                  borderRadius: FundusRadius.smAll,
                  child: Image.file(
                    File(path),
                    width: 56,
                    height: 32,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            Expanded(
              child: Text(
                chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            Text(
              _formatDuration(chapter.position),
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.textFaint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDate(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}.'
    '${value.month.toString().padLeft(2, '0')}.${value.year}';

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
    final vault = FundusScope.of(context).library.library;
    final credits = creditsOf(work, library: vault);
    if (credits.isEmpty) {
      return const FundusEmptyState(
        title: 'Keine Personen erfasst',
        reason:
            'Personen entstehen beim Import aus Metadaten; von Hand ergänzte '
            'Angaben bleiben bei späteren Scans geschützt.',
      );
    }
    final theme = Theme.of(context);
    final tokens = context.fundus;
    // Nach Rolle gruppiert, wie im Entwurf: erst wer es gemacht hat, dann wer
    // es gelesen hat.
    // Nach Rolle gruppiert, wie im Entwurf.
    final byRole = <String, List<PersonCredit>>{};
    for (final credit in credits) {
      final group = byRole.putIfAbsent(credit.roleLabel, () => []);
      if (!group.any((person) => person.name == credit.name)) {
        group.add(credit);
      }
    }

    return ListView(
      padding: _contentPadding(context),
      children: [
        for (final entry in byRole.entries) ...[
          Text(
            entry.key.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: tokens.textFaint,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: FundusSpace.x3),
          Wrap(
            spacing: FundusSpace.x4,
            runSpacing: FundusSpace.x4,
            children: [
              for (final person in entry.value)
                _PersonTile(
                  name: person.name,
                  role: entry.key,
                  imagePath: person.imagePath,
                  root: vault?.root.path,
                ),
            ],
          ),
          const SizedBox(height: FundusSpace.x8),
        ],
      ],
    );
  }
}

/// Eine Person als Kachel: Bild, Name, Rolle — und ein Weg zu ihr.
class _PersonTile extends StatelessWidget {
  const _PersonTile({
    required this.name,
    required this.role,
    this.imagePath,
    this.root,
  });

  final String name;
  final String role;
  final String? imagePath;
  final String? root;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;
    return SizedBox(
      width: 132,
      child: InkWell(
        borderRadius: FundusRadius.mdAll,
        onTap: () => FundusScope.of(context).navigation.go(PersonRoute(name)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PersonAvatar(
              name: name,
              size: 132,
              imagePath: imagePath,
              root: root,
            ),
            const SizedBox(height: FundusSpace.x2),
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              role,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.textFaint,
              ),
            ),
          ],
        ),
      ),
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
  /// Was die anderen Geräte zu diesem Werk sagen. Erst gefragt, wenn jemand
  /// hersieht — es ist eine Runde übers Netz.
  Future<List<({String peerName, String serverId, RemoteProgress progress})>>?
  _elsewhere;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _elsewhere ??= FundusScope.of(
      context,
    ).sync.progressEverywhere(widget.work.id);
  }

  void _askAgain() => setState(() {
    _elsewhere = FundusScope.of(
      context,
    ).sync.progressEverywhere(widget.work.id);
  });

  /// Übernimmt den Stand von drüben — hier, auf diesem Gerät.
  Future<void> _take(RemoteProgress progress) async {
    final scope = FundusScope.of(context);
    final vault = scope.library.library;
    if (vault == null || vault.isReadOnly || _busy) return;
    setState(() => _busy = true);
    try {
      vault.saveMediaProgress(
        workId: widget.work.id,
        position: progress.position,
        // Ohne Datei gilt der Stand für das Werk als Ganzes; die
        // Bibliothek erwartet trotzdem eine Angabe.
        fileId: progress.fileId ?? progress.position.fileId ?? '',
        finished: progress.finished,
        deviceId: scope.settings.deviceKey,
        updatedAt: progress.updatedAt,
        checkpoint: true,
      );
      scope.library.refreshWork(widget.work.id);
    } on Object {
      // Ein Stand, der sich nicht schreiben lässt, ist kein Grund, die Seite
      // zu verlieren; der Knopf bleibt stehen.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _takeRevision(LibraryPlaybackRevision revision) async {
    final scope = FundusScope.of(context);
    final vault = scope.library.library;
    if (vault == null || vault.isReadOnly || _busy || revision.fileId == null) {
      return;
    }
    setState(() => _busy = true);
    try {
      vault.saveMediaProgress(
        workId: widget.work.id,
        fileId: revision.fileId!,
        position: revision.position,
        finished: revision.finished,
        deviceId: scope.settings.deviceKey,
        updatedAt: revision.createdAt,
        checkpoint: true,
      );
      scope.library.refreshWork(widget.work.id);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final theme = Theme.of(context);
    final tokens = context.fundus;
    final mine = scope.library.library?.loadProgress(widget.work.id);
    final latestByDevice = <String, LibraryPlaybackRevision>{};
    for (final revision
        in scope.library.library?.listCheckpointRevisions(widget.work.id) ??
            const <LibraryPlaybackRevision>[]) {
      final previous = latestByDevice[revision.deviceId];
      if (previous == null || revision.createdAt.isAfter(previous.createdAt)) {
        latestByDevice[revision.deviceId] = revision;
      }
    }
    final localDevice = latestByDevice[scope.settings.deviceKey];
    final order = [
      for (final track
          in scope.library.library?.playbackTracks(widget.work.id) ??
              const <LibraryPlaybackTrack>[])
        track.fileId,
    ];

    return FutureBuilder<
      List<({String peerName, String serverId, RemoteProgress progress})>
    >(
      future: _elsewhere,
      builder: (context, snapshot) {
        final answers = snapshot.data ?? const [];
        final waiting =
            snapshot.connectionState == ConnectionState.waiting &&
            scope.settings.peers.isNotEmpty;

        return ListView(
          padding: _contentPadding(context),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'STAND PRO GERÄT',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: tokens.textFaint,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                if (waiting)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton(
                    onPressed: _askAgain,
                    child: const Text('Jetzt abgleichen'),
                  ),
              ],
            ),
            const SizedBox(height: FundusSpace.x3),
            _DeviceRow(
              name: '${scope.settings.deviceName} · dieses Gerät',
              icon: FundusIcons.devices,
              position: localDevice != null
                  ? _positionLabel(localDevice.position, localDevice.finished)
                  : mine == null
                  ? null
                  : _positionLabel(mine.position, mine.finished),
              fraction: localDevice != null
                  ? _fraction(localDevice.position)
                  : mine == null
                  ? null
                  : _fraction(mine.position),
              when: localDevice?.createdAt ?? mine?.updatedAt,
              action: null,
            ),
            for (final entry in latestByDevice.entries)
              if (entry.key != scope.settings.deviceKey &&
                  !answers.any(
                    (answer) => answer.progress.deviceId == entry.key,
                  ))
                _DeviceRow(
                  name: entry.key,
                  icon: FundusIcons.devices,
                  position: _positionLabel(
                    entry.value.position,
                    entry.value.finished,
                  ),
                  fraction: _fraction(entry.value.position),
                  when: entry.value.createdAt,
                  ahead:
                      mine == null ||
                      comparePositions(
                            entry.value.position,
                            mine.position,
                            fileOrder: order,
                          ) >
                          0,
                  action: _busy
                      ? null
                      : () => unawaited(_takeRevision(entry.value)),
                ),
            for (final answer in answers)
              _DeviceRow(
                name: answer.peerName,
                icon: FundusIcons.originStream,
                position: _positionLabel(
                  answer.progress.position,
                  answer.progress.finished,
                ),
                fraction: _fraction(answer.progress.position),
                when: answer.progress.updatedAt,
                ahead:
                    mine == null ||
                    comparePositions(
                          answer.progress.position,
                          mine.position,
                          fileOrder: order,
                        ) >
                        0,
                action: _busy ? null : () => unawaited(_take(answer.progress)),
              ),
            if (answers.isEmpty && !waiting)
              Padding(
                padding: const EdgeInsets.only(top: FundusSpace.x4),
                child: Text(
                  scope.settings.peers.isEmpty
                      ? 'Dieses Gerät ist mit keinem anderen gekoppelt. Sobald '
                            'eines dazukommt, steht sein Stand hier.'
                      : 'Kein anderes Gerät hat gerade geantwortet. Der Stand '
                            'von hier bleibt davon unberührt.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.textFaint,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// „S02E04 · 00:27:10" — was von einem Stand zu sehen sein soll.
  String _positionLabel(MediaPosition position, bool finished) {
    if (finished) return 'abgeschlossen';
    final label = position.label;
    if (label != null && label.trim().isNotEmpty) return label;
    final value = position.numericValue ?? 0;
    return switch (position.kind) {
      MediaPositionKind.time => formatPlaybackTime(
        Duration(seconds: value.round()),
      ),
      MediaPositionKind.page => 'Seite ${value.round()}',
      _ => '${(value * 100).round()} %',
    };
  }

  double? _fraction(MediaPosition position) {
    final total = position.total;
    final value = position.numericValue;
    if (total == null || value == null || total <= 0) return null;
    return (value / total).clamp(0.0, 1.0);
  }
}

/// Eine Zeile der Geräteliste: wer, wo, wann — und was man damit tun kann.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.name,
    required this.icon,
    required this.position,
    required this.fraction,
    required this.when,
    required this.action,
    this.ahead = false,
  });

  final String name;
  final IconData icon;

  /// Null heißt: dieses Gerät hat zu diesem Werk keinen Stand.
  final String? position;
  final double? fraction;
  final DateTime? when;

  /// Ob dieses Gerät weiter ist als das hier. Nur dann lohnt „übernehmen".
  final bool ahead;
  final VoidCallback? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.fundus;

    return Container(
      margin: const EdgeInsets.only(bottom: FundusSpace.x2),
      padding: const EdgeInsets.all(FundusSpace.x3),
      decoration: BoxDecoration(
        color: ahead ? tokens.accentTint(0.12) : Colors.transparent,
        borderRadius: FundusRadius.mdAll,
        border: Border.fromBorderSide(
          BorderSide(color: ahead ? tokens.accent : tokens.divider),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: FundusIcons.sizeLg, color: tokens.textFaint),
          const SizedBox(width: FundusSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (ahead) ...[
                      const SizedBox(width: FundusSpace.x2),
                      const FundusTag('weiter', tone: FundusTagTone.accent),
                    ],
                  ],
                ),
                Text(
                  position ?? 'kein Stand für dieses Werk',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: tokens.textFaint,
                  ),
                ),
                if (fraction case final share?) ...[
                  const SizedBox(height: FundusSpace.x2),
                  ClipRRect(
                    borderRadius: FundusRadius.smAll,
                    child: LinearProgressIndicator(
                      value: share,
                      minHeight: 3,
                      backgroundColor: tokens.divider,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: FundusSpace.x3),
          if (when case final moment?)
            Text(
              _ago(moment),
              style: theme.textTheme.labelMedium?.copyWith(
                color: tokens.textFaint,
              ),
            ),
          if (action case final take?) ...[
            const SizedBox(width: FundusSpace.x3),
            OutlinedButton(
              onPressed: take,
              child: const Text('Stand übernehmen'),
            ),
          ],
        ],
      ),
    );
  }

  static String _ago(DateTime value) {
    final passed = DateTime.now().difference(value.toLocal());
    if (passed.inMinutes < 1) return 'jetzt';
    if (passed.inMinutes < 60) return 'vor ${passed.inMinutes} Min';
    if (passed.inHours < 24) return 'vor ${passed.inHours} Std';
    if (passed.inDays == 1) return 'gestern';
    if (passed.inDays < 31) return 'vor ${passed.inDays} Tagen';
    return 'vor ${passed.inDays ~/ 30} Monaten';
  }
}

/// „Das mag ich."/// „Das mag ich."
///
/// In the vault rather than on this device, because it is a statement about
/// the work and should be true on the phone as well.
/// „Zur Liste" — dasselbe Blatt für ein Werk wie für eine Folge.
class _ListButton extends StatelessWidget {
  const _ListButton({required this.work});

  final WorkView work;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: () =>
        unawaited(showAddToList(context, workId: work.id, label: work.title)),
    icon: Icon(FundusIcons.lists, size: FundusIcons.sizeSm),
    label: const Text('Zur Liste'),
  );
}

class _FavouriteButton extends StatelessWidget {
  const _FavouriteButton({required this.work});

  final WorkView work;

  @override
  Widget build(BuildContext context) {
    final scope = FundusScope.of(context);
    final tokens = context.fundus;
    final on = work.summary.favourite;
    return IconButton(
      onPressed: () => scope.toggleFavourite(work),
      tooltip: on ? 'Aus den Favoriten nehmen' : 'Zu den Favoriten',
      icon: Icon(
        on ? FundusIcons.favourite : FundusIcons.favourites,
        size: FundusIcons.sizeLg,
        color: on ? tokens.accent : tokens.textFaint,
      ),
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
