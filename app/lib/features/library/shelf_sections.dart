import 'dart:math';

import '../../data/work_view.dart';

/// Die Reihen, die vor einem Regal stehen.
///
/// Sie sind keine Ablage, sondern Ansichten auf dieselben Werke: „zuletzt
/// hinzugefügt" ist eine Sortierung, „weiterschauen" ein Zustand, „zufällig
/// entdecken" ein Würfel. Deshalb stehen sie hier als Abfragen und nicht als
/// Listen, die irgendwo mitgeführt werden müssten.
enum ShelfSection {
  all('Alle'),
  continuing('Weiterschauen'),
  recent('Zuletzt hinzugefügt'),
  surprise('Zufällig entdecken');

  const ShelfSection(this.label);

  /// Was über der Reihe steht.
  final String label;

  static ShelfSection? byName(String? value) {
    for (final section in values) {
      if (section.name == value) return section;
    }
    return null;
  }
}

/// Die Werke einer Reihe, in ihrer Reihenfolge.
///
/// [limit] ist die Länge der Reihe auf der Bühne; ohne ihn kommt alles, was
/// dazugehört — das ist die Seite, auf die die Überschrift führt.
List<WorkView> worksInSection(
  ShelfSection section,
  List<WorkView> works, {
  required int seed,
  int? limit,
}) {
  final chosen = switch (section) {
    ShelfSection.all => [...works],
    ShelfSection.continuing => _continuing(works),
    ShelfSection.recent => _recent(works),
    ShelfSection.surprise => [...works]..shuffle(Random(seed)),
  };
  if (limit == null || chosen.length <= limit) {
    return List.unmodifiable(chosen);
  }
  return List.unmodifiable(chosen.take(limit));
}

/// Angefangen und nicht zu Ende, das zuletzt Gehörte zuerst.
List<WorkView> _continuing(List<WorkView> works) {
  final open = works
      .where((work) => work.hasProgress && !work.finished)
      .toList();
  open.sort((left, right) {
    final leftAt = left.summary.lastListenedAt;
    final rightAt = right.summary.lastListenedAt;
    if (leftAt == null && rightAt == null) return 0;
    if (leftAt == null) return 1;
    if (rightAt == null) return -1;
    return rightAt.compareTo(leftAt);
  });
  return open;
}

List<WorkView> _recent(List<WorkView> works) => [
  ...works,
]..sort((left, right) => right.summary.addedAt.compareTo(left.summary.addedAt));
