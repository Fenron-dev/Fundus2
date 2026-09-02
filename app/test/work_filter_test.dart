import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/media_type.dart';
import 'package:fundus/data/work_filter.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

WorkView work({
  required String id,
  required String title,
  String kind = 'audiobook',
  String author = 'Karl May',
  String? series,
  String availability = 'available',
  DateTime? addedAt,
  List<String> tags = const [],
}) => WorkView.fromSummary(
  LibraryWorkSummary(
    id: id,
    kind: kind,
    title: title,
    author: author,
    fileCount: 1,
    addedAt: addedAt ?? DateTime(2026, 1, 1),
    series: series,
    availability: availability,
    tags: tags,
  ),
);

void main() {
  final works = [
    work(id: 'a', title: 'Winnetou I', series: 'Winnetou'),
    work(
      id: 'b',
      title: 'Der Ölprinz',
      availability: 'remote',
      addedAt: DateTime(2026, 2, 1),
    ),
    work(
      id: 'c',
      title: 'Klingenwind',
      kind: 'manga',
      author: 'R. Tomobe',
      availability: 'offline_copy',
    ),
    work(id: 'd', title: 'Steuer 2025', kind: 'steuerunterlagen'),
  ];

  test('eine Ansicht für alle Herkünfte', () {
    expect(const WorkFilter().apply(works), hasLength(4));
  });

  test('Herkunft ist ein Filter, kein eigener Bereich', () {
    final offline = const WorkFilter(
      origins: {FundusOrigin.offline},
    ).apply(works);

    expect(offline.map((w) => w.id), ['c']);
  });

  test('der Medientyp grenzt ein, ohne Unbekanntes zu verlieren', () {
    final audiobooks = WorkFilter(
      mediaTypeId: MediaTypes.audiobook.id,
    ).apply(works);
    final unassigned = const WorkFilter(unassignedOnly: true).apply(works);

    expect(audiobooks.map((w) => w.id), unorderedEquals(['a', 'b']));
    expect(unassigned.map((w) => w.id), ['d']);
  });

  test('die Suche greift auf Titel und Untertitel', () {
    expect(const WorkFilter(text: 'tomobe').apply(works).map((w) => w.id), [
      'c',
    ]);
  });

  test('ein Leerzustand nennt seine Ursache', () {
    const filter = WorkFilter(
      text: 'thule',
      origins: {FundusOrigin.unreachable},
    );

    expect(filter.apply(works), isEmpty);
    expect(filter.emptyReason(), contains('die Suche „thule"'));
    expect(filter.emptyReason(), contains('Nicht erreichbar'));
    expect(filter.activeFilterCount, 2);
  });

  test('ohne Filter erklärt der Leerzustand die leere Bibliothek', () {
    expect(const WorkFilter().emptyReason(), contains('noch nichts indexiert'));
  });

  group('Sortierung', () {
    test('nach Titel', () {
      expect(
        const WorkFilter(sort: WorkSort.title).apply(works).map((w) => w.title),
        ['Der Ölprinz', 'Klingenwind', 'Steuer 2025', 'Winnetou I'],
      );
    });

    test('zuletzt hinzugefügt zuerst', () {
      expect(
        const WorkFilter(sort: WorkSort.recentlyAdded).apply(works).first.id,
        'b',
      );
    });
  });

  group('Gruppierung', () {
    test('fehlende Felder landen in einer benannten Gruppe', () {
      final groups = WorkGrouping.group(works, GroupingMode.series);

      expect(groups.map((g) => g.label), contains('Winnetou'));
      expect(groups.map((g) => g.label), contains('Einzeln'));
      expect(groups.firstWhere((g) => g.label == 'Einzeln').count, 3);
    });

    test('nach Urheber', () {
      final groups = WorkGrouping.group(works, GroupingMode.author);

      expect(groups.map((g) => g.label), ['Karl May', 'R. Tomobe']);
      expect(groups.first.count, 3);
    });

    test('ohne System-Angabe wird benannt statt verschwiegen', () {
      final groups = WorkGrouping.group(works, GroupingMode.round);

      expect(groups.single.label, 'Ohne Runde');
    });
  });
}
