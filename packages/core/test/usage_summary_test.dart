import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

/// A year in numbers, from the play events this device wrote down.
void main() {
  FundusDatabase withWorks() {
    final db = FundusDatabase.inMemory();
    for (final (id, kind, title) in const [
      ('w-book', 'audiobook', 'Der Schacht'),
      ('w-film', 'movie', 'Nordwind'),
      ('w-secret', 'movie', 'Geheim'),
    ]) {
      db.rawExecute(
        'INSERT INTO works (id, source_id, kind, source_path, title, '
        "added_at, status) VALUES (?, ?, ?, ?, ?, 0, 'available')",
        [id, FundusDatabase.localSourceId, kind, id, title],
      );
    }
    return db;
  }

  void play(FundusDatabase db, String work, DateTime at, int seconds) =>
      db.recordPlayEvent(
        workId: work,
        startedAt: at,
        endedAt: at.add(Duration(seconds: seconds)),
        secondsPlayed: seconds,
        deviceId: 'phone',
      );

  test('a year adds up by kind, month, work and day', () {
    final db = withWorks();
    addTearDown(db.close);
    play(db, 'w-book', DateTime(2026, 1, 3, 20), 3600);
    play(db, 'w-book', DateTime(2026, 1, 4, 20), 1800);
    play(db, 'w-book', DateTime(2026, 1, 5, 20), 600);
    play(db, 'w-film', DateTime(2026, 3, 1, 21), 7200);
    play(db, 'w-secret', DateTime(2026, 3, 2, 22), 5400);
    // Another year does not count.
    play(db, 'w-film', DateTime(2025, 12, 31, 21), 7200);

    final summary = db.usageSummary(
      from: DateTime(2026),
      until: DateTime(2027),
      excludedWorkIds: {'w-secret'},
    );
    expect(summary.totalSeconds, 3600 + 1800 + 600 + 7200);
    expect(summary.secondsByKind, {'audiobook': 6000, 'movie': 7200});
    expect(summary.secondsByMonth, {1: 6000, 3: 7200});
    expect(summary.topWorks.map((work) => work.title), [
      'Nordwind',
      'Der Schacht',
    ]);
    expect(summary.activeDays, hasLength(4));
    expect(summary.longestStreak, 3);
  });

  test('a protected work leaves no trace in the numbers', () {
    final db = withWorks();
    addTearDown(db.close);
    play(db, 'w-secret', DateTime(2026, 3, 2, 22), 5400);
    final summary = db.usageSummary(
      from: DateTime(2026),
      until: DateTime(2027),
      excludedWorkIds: {'w-secret'},
    );
    expect(summary.totalSeconds, 0);
    expect(summary.topWorks, isEmpty);
    expect(summary.activeDays, isEmpty);
  });

  test('an event for a work that is gone is not written', () {
    final db = withWorks();
    addTearDown(db.close);
    play(db, 'w-missing', DateTime(2026, 3, 2, 22), 5400);
    final rows = db.rawQuery('SELECT COUNT(*) AS n FROM play_events');
    expect(rows.single['n'], 0);
  });
}
