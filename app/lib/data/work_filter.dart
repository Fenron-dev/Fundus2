import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

import 'media_type.dart';
import 'work_view.dart';

enum WorkSort {
  recentlyAdded('Zuletzt hinzugefügt'),
  title('Titel A–Z'),
  progress('Fortschritt'),
  series('Reihe');

  const WorkSort(this.label);

  final String label;
}

/// What the content column is currently showing.
///
/// Filters apply in every grouping, the folder view included: real structure,
/// but only the matching files.
final class WorkFilter {
  const WorkFilter({
    this.text = '',
    this.mediaTypeId,
    this.origins = const {},
    this.sort = WorkSort.recentlyAdded,
    this.grouping = GroupingMode.tiles,
    this.unassignedOnly = false,
    this.favouritesOnly = false,
    this.tags = const {},
    this.sourceId,
  });

  final String text;
  final String? mediaTypeId;

  /// Empty means every origin — "offline verfügbar" is one of these, a filter
  /// rather than a section of its own.
  final Set<FundusOrigin> origins;
  final WorkSort sort;
  final GroupingMode grouping;

  /// Works whose kind no type claims. They stay reachable instead of being
  /// silently dropped.
  final bool unassignedOnly;

  /// Only what somebody marked as a favourite.
  final bool favouritesOnly;

  /// Every one of these has to be on the work. Chips read as „and also".
  ///
  /// Gemeint sind Schlagworte *und* Genres: „Shōnen" steht bei dem einen Werk
  /// als Genre vom Abgleich, beim anderen als Schlagwort von Hand. Wer danach
  /// filtert, meint beide.
  final Set<String> tags;

  /// One machine's shelf out of the several this device holds.
  ///
  /// The vault of a phone is a shell where several Fundus libraries come
  /// together; this is what separates them again. Null is „alle Geräte",
  /// which is the normal way to look at it — a work is a work, whichever
  /// machine keeps its files.
  final String? sourceId;

  bool get hasActiveFilters =>
      text.isNotEmpty ||
      origins.isNotEmpty ||
      unassignedOnly ||
      favouritesOnly ||
      tags.isNotEmpty ||
      sourceId != null;

  int get activeFilterCount =>
      (text.isEmpty ? 0 : 1) +
      origins.length +
      (unassignedOnly ? 1 : 0) +
      (favouritesOnly ? 1 : 0) +
      tags.length;

  WorkFilter copyWith({
    String? text,
    String? mediaTypeId,
    bool clearMediaType = false,
    Set<FundusOrigin>? origins,
    WorkSort? sort,
    GroupingMode? grouping,
    bool? unassignedOnly,
    bool? favouritesOnly,
    Set<String>? tags,
    String? sourceId,
    bool clearSource = false,
  }) => WorkFilter(
    text: text ?? this.text,
    mediaTypeId: clearMediaType ? null : (mediaTypeId ?? this.mediaTypeId),
    origins: origins ?? this.origins,
    sort: sort ?? this.sort,
    grouping: grouping ?? this.grouping,
    unassignedOnly: unassignedOnly ?? this.unassignedOnly,
    favouritesOnly: favouritesOnly ?? this.favouritesOnly,
    tags: tags ?? this.tags,
    sourceId: clearSource ? null : (sourceId ?? this.sourceId),
  );

  /// Wonach sich ein Werk filtern lässt: seine Schlagworte und seine Genres.
  static Set<String> labelsOf(WorkView work) => {
    ...work.summary.tags,
    ...work.summary.genres,
  };

  /// Why the result is empty. An empty state without a cause is a dead end,
  /// so the screen always has this sentence to show.
  String emptyReason() {
    final reasons = <String>[];
    if (text.isNotEmpty) reasons.add('die Suche „$text"');
    if (favouritesOnly) reasons.add('die Beschränkung auf Favoriten');
    if (tags.isNotEmpty) reasons.add('die Schlagworte ${tags.join(', ')}');
    if (sourceId != null) reasons.add('das gewählte Gerät');
    if (origins.isNotEmpty) {
      reasons.add(
        'der Herkunftsfilter ${origins.map((o) => o.label).join(', ')}',
      );
    }
    if (mediaTypeId != null) {
      final type = MediaTypes.byId(mediaTypeId!);
      if (type != null) reasons.add('der Bereich ${type.label}');
    }
    if (reasons.isEmpty) {
      return 'In dieser Bibliothek ist noch nichts indexiert. '
          'Ein Scan füllt sie.';
    }
    return 'Es filtern gerade: ${reasons.join(' und ')}.';
  }

  List<WorkView> apply(List<WorkView> works) {
    final type = mediaTypeId == null ? null : MediaTypes.byId(mediaTypeId!);
    final needle = text.trim().toLowerCase();

    final matched = works.where((work) {
      if (unassignedOnly && work.mediaType != null) return false;
      if (favouritesOnly && !work.summary.favourite) return false;
      if (tags.isNotEmpty && !tags.every(labelsOf(work).contains)) {
        return false;
      }
      if (type != null && work.mediaType?.id != type.id) return false;
      if (origins.isNotEmpty && !origins.contains(work.origin)) return false;
      if (sourceId != null && work.summary.sourceId != sourceId) return false;
      if (needle.isEmpty) return true;
      return work.title.toLowerCase().contains(needle) ||
          work.subtitle.toLowerCase().contains(needle);
    }).toList();

    matched.sort(_comparator);
    return matched;
  }

  int Function(WorkView, WorkView) get _comparator => switch (sort) {
    WorkSort.title => (a, b) => a.title.toLowerCase().compareTo(
      b.title.toLowerCase(),
    ),
    WorkSort.recentlyAdded => (a, b) => b.summary.addedAt.compareTo(
      a.summary.addedAt,
    ),
    WorkSort.progress => (a, b) => (b.progressFraction ?? 0).compareTo(
      a.progressFraction ?? 0,
    ),
    WorkSort.series => (a, b) {
      final series = (a.summary.series ?? a.title).toLowerCase().compareTo(
        (b.summary.series ?? b.title).toLowerCase(),
      );
      if (series != 0) return series;
      return (a.summary.seriesSequence ?? 0).compareTo(
        b.summary.seriesSequence ?? 0,
      );
    },
  };
}

/// One row of a grouped view — a folder, a series, a system, a month.
final class WorkGroup {
  const WorkGroup({required this.label, required this.works});

  final String label;
  final List<WorkView> works;

  int get count => works.length;
}

/// Groups works for the non-tile groupings.
///
/// These are queries over properties, never materialised tables: a work whose
/// field changes simply lands in a different group next time, with nothing to
/// keep consistent.
abstract final class WorkGrouping {
  static List<WorkGroup> group(List<WorkView> works, GroupingMode mode) {
    String? Function(WorkView) key = switch (mode) {
      GroupingMode.series => (work) => work.summary.series,
      GroupingMode.author => (work) => work.summary.author,
      GroupingMode.folder => (work) => _folderOf(work),
      GroupingMode.fileType => (work) => work.kind,
      GroupingMode.system => (work) => work.summary.series,
      GroupingMode.round => (work) => work.summary.tags.firstOrNull,
      GroupingMode.topic => (work) => work.summary.genres.firstOrNull,
      GroupingMode.time => (work) => _monthOf(work),
      GroupingMode.albums => (work) => work.summary.series,
      GroupingMode.tiles || GroupingMode.table => (_) => null,
    };

    final buckets = <String, List<WorkView>>{};
    for (final work in works) {
      // A missing field is not an error: the work lands in an explicit
      // "ohne …" group, from where the folder name can be adopted later.
      final label = key(work)?.trim();
      buckets
          .putIfAbsent(
            label == null || label.isEmpty ? _missingLabel(mode) : label,
            () => [],
          )
          .add(work);
    }

    final groups =
        buckets.entries
            .map((entry) => WorkGroup(label: entry.key, works: entry.value))
            .toList()
          ..sort(
            (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
          );
    return groups;
  }

  static String _missingLabel(GroupingMode mode) => switch (mode) {
    GroupingMode.system => 'Ohne System-Angabe',
    GroupingMode.round => 'Ohne Runde',
    GroupingMode.topic => 'Ohne Thema',
    GroupingMode.author => 'Ohne Urheber',
    GroupingMode.series => 'Einzeln',
    GroupingMode.time => 'Ohne Datum',
    _ => 'Ohne Zuordnung',
  };

  /// Where a work lies, as the path says it.
  ///
  /// It used to be read off the cover's file path, which named the wrong
  /// thing twice over: a work whose cover Fundus fetched landed under
  /// „covers", and one without a cover under „Bibliothekswurzel" no matter
  /// where it actually was. The work's own place in the vault is the answer,
  /// and it is the whole path — „Podcasts/Auf ein Bier" says what „Auf ein
  /// Bier" alone does not.
  static String _folderOf(WorkView work) {
    final parts = work.summary.sourcePath
        .split(RegExp(r'[/\\]'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length < 2) return 'Bibliothekswurzel';
    return parts.sublist(0, parts.length - 1).join('/');
  }

  static String _monthOf(WorkView work) {
    final date = work.summary.addedAt;
    const months = [
      'Januar',
      'Februar',
      'März',
      'April',
      'Mai',
      'Juni',
      'Juli',
      'August',
      'September',
      'Oktober',
      'November',
      'Dezember',
    ];
    return '${months[date.month - 1]} ${date.year}';
  }
}

/// Turning a view into something the vault can store, and back.
///
/// The stored shape is the core's own query, so a view saved by one client
/// means the same thing to the next. What does not survive is „Ordnen nach":
/// that is how a list is laid out, not what is in it, and people flip it
/// while looking rather than as part of what they were looking for.
extension WorkFilterQuery on WorkFilter {
  LibraryWorkQuery toQuery() => LibraryWorkQuery(
    text: text,
    kinds: mediaTypeId == null
        ? const {}
        : MediaTypes.byId(mediaTypeId!)?.workKinds ?? const {},
    offlineOnly: origins.contains(FundusOrigin.offline),
    sort: switch (sort) {
      WorkSort.recentlyAdded => LibraryWorkSort.recentlyAdded,
      WorkSort.title => LibraryWorkSort.title,
      WorkSort.progress => LibraryWorkSort.progress,
      WorkSort.series => LibraryWorkSort.series,
    },
  );

  static WorkFilter fromQuery(LibraryWorkQuery query) {
    final type = MediaTypes.all
        .where((entry) => entry.workKinds.intersection(query.kinds).isNotEmpty)
        .firstOrNull;
    return WorkFilter(
      text: query.text,
      mediaTypeId: type?.id,
      origins: query.offlineOnly ? const {FundusOrigin.offline} : const {},
      tags: query.tags,
      sort: switch (query.sort) {
        LibraryWorkSort.title => WorkSort.title,
        LibraryWorkSort.progress => WorkSort.progress,
        LibraryWorkSort.series => WorkSort.series,
        _ => WorkSort.recentlyAdded,
      },
    );
  }
}
