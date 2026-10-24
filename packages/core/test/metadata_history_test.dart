import 'dart:convert';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  final at = DateTime.utc(2026, 10, 24);
  MetadataFieldState state(Object? value, {bool locked = false}) =>
      MetadataFieldState(
        present: true,
        value: value,
        source: 'online',
        originAt: at,
        locked: locked,
      );
  MetadataFieldChange change(
    String work,
    String field,
    Object? old,
    Object? next,
  ) => MetadataFieldChange(
    workId: work,
    field: field,
    before: state(old),
    after: state(next),
  );
  MetadataChangeBatch batch(String id, {List<MetadataFieldChange>? fields}) =>
      MetadataChangeBatch(
        id: id,
        source: 'tmdb',
        at: at,
        changes: fields ?? [change('work', 'title', 'Alt', 'Neu')],
      );

  test(
    'batch roundtrip preserves values, provenance, locks and explicit absence',
    () {
      final original = MetadataChangeBatch(
        id: 'batch',
        source: 'user',
        at: at,
        changes: [
          MetadataFieldChange(
            workId: 'work',
            field: 'publisher',
            before: MetadataFieldState(present: false),
            after: state('Verlag', locked: true),
          ),
          change('work', 'genres', ['Drama'], ['Drama', 'Fantasy']),
          change('work', 'property:translator', null, 'Name'),
        ],
      );
      final history = MetadataHistory().append(original);
      final loaded = MetadataHistory.decode(history.encode());
      expect(loaded.encode(), history.encode());
      expect(loaded.batches.single.changes.first.before.present, isFalse);
      expect(loaded.batches.single.changes.first.after.locked, isTrue);
      expect(loaded.batches.single.changes.first.after.originAt, at);
    },
  );

  test('history values cannot be changed through editor collections', () {
    final values = ['Drama'];
    final original = state({'genres': values});
    values.add('Fantasy');
    expect((original.value as Map)['genres'], ['Drama']);
    expect(() => (original.value as Map)['other'] = 1, throwsUnsupportedError);
    expect(
      () => ((original.value as Map)['genres'] as List).add('X'),
      throwsUnsupportedError,
    );
  });

  test(
    'legacy format one is read conservatively and upgraded without losing changes',
    () {
      final value =
          jsonDecode(MetadataHistory().append(batch('legacy')).encode()) as Map;
      value['format_version'] = 1;
      for (final raw in (value['batches'] as List).single['changes'] as List) {
        (raw as Map).remove('protected');
      }
      final restored = MetadataHistory.decode(jsonEncode(value));
      expect(
        restored.batches.single.changes.every((change) => change.protected),
        isTrue,
      );
      expect(jsonDecode(restored.encode())['format_version'], 2);
    },
  );

  test(
    'map order does not create changes but list order remains significant',
    () {
      expect(state({'a': 1, 'b': 2}).sameAs(state({'b': 2, 'a': 1})), isTrue);
      expect(state(['A', 'B']).sameAs(state(['B', 'A'])), isFalse);
      expect(state('A').sameAs(state('A', locked: true)), isFalse);
      expect(
        batch(
          'none',
          fields: [change('work', 'title', 'Same', 'Same')],
        ).changes,
        isEmpty,
      );
    },
  );

  test(
    'undo preview is per field and rejects intervening value or lock changes',
    () {
      final edit = batch(
        'edit',
        fields: [
          change('first', 'title', 'Alt', 'Neu'),
          change('first', 'genres', ['Drama'], ['Drama', 'Fantasy']),
          change('second', 'title', 'Früher', 'Jetzt'),
        ],
      );
      final plan = MetadataUndoPlan.preview(
        batch: edit,
        current: (work, field) {
          if (work == 'second') return state('Jetzt', locked: true);
          return field == 'title' ? state('Neu') : state(['Drama', 'Mystery']);
        },
      );
      expect(plan.applicable.map((change) => change.field), ['title']);
      expect(plan.conflicts, hasLength(2));
      expect(plan.applicable.single.before.value, 'Alt');
      final onlyTitle = MetadataUndoPlan.preview(
        batch: edit,
        selected: (change) =>
            change.workId == 'first' && change.field == 'title',
        current: (_, _) => state('Neu'),
      );
      expect(onlyTitle.applicable, hasLength(1));
      expect(onlyTitle.conflicts, isEmpty);
    },
  );

  test('hidden or missing works never leak through an undo preview', () {
    final plan = MetadataUndoPlan.preview(
      batch: batch('edit'),
      current: (_, _) => null,
    );
    expect(plan.applicable, isEmpty);
    expect(plan.conflicts, isEmpty);
  });

  test('a preview must be recalculated before applying it', () {
    final edit = batch('edit');
    var current = state('Neu');
    expect(
      MetadataUndoPlan.preview(
        batch: edit,
        current: (_, _) => current,
      ).applicable,
      hasLength(1),
    );
    current = state('Zwischenzeitlich korrigiert');
    final checked = MetadataUndoPlan.preview(
      batch: edit,
      current: (_, _) => current,
    );
    expect(checked.applicable, isEmpty);
    expect(checked.conflicts, hasLength(1));
  });

  test('retention removes whole old batches, not individual work fields', () {
    var history = MetadataHistory();
    for (final id in ['one', 'two', 'three']) {
      history = history.append(
        batch(
          id,
          fields: [
            change('first', 'title', 'A', id),
            change('second', 'title', 'B', id),
          ],
        ),
        retainBatches: 2,
      );
    }
    expect(history.batches.map((batch) => batch.id), ['two', 'three']);
    expect(history.batches.every((batch) => batch.changes.length == 2), isTrue);
    final one = MetadataHistory().append(batch('new'));
    final budget = one.encode().length + 50;
    final pruned = history.append(batch('new'), byteBudget: budget);
    expect(pruned.batches.map((batch) => batch.id), ['new']);
    expect(
      () => history.append(batch('too-big'), byteBudget: 1),
      throwsFormatException,
    );
    expect(history.batches, hasLength(2));
    final unicode = batch(
      'unicode',
      fields: [change('work', 'title', 'Alt', '日本語')],
    );
    final exact = utf8
        .encode(MetadataHistory().append(unicode).encode())
        .length;
    expect(
      history.append(unicode, byteBudget: exact).batches.single.id,
      'unicode',
    );
    expect(
      () => history.append(unicode, byteBudget: exact - 1),
      throwsFormatException,
    );
  });

  test('retries are idempotent but conflicting batch IDs are rejected', () {
    final edit = batch('same');
    final history = MetadataHistory().append(edit);
    expect(identical(history.append(edit), history), isTrue);
    expect(
      () => history.append(
        batch('same', fields: [change('work', 'title', 'A', 'B')]),
      ),
      throwsFormatException,
    );
    expect(
      () => batch(
        'duplicate',
        fields: [
          change('work', 'title', 'A', 'B'),
          change('work', 'title', 'B', 'C'),
        ],
      ),
      throwsFormatException,
    );
  });

  test('rollback batches remain a new traceable edit', () {
    final undone = MetadataChangeBatch(
      id: 'undo',
      source: 'user',
      at: at,
      reversesBatchId: 'original',
      changes: [change('work', 'title', 'Neu', 'Alt')],
    );
    final history = MetadataHistory().append(batch('original')).append(undone);
    final loaded = MetadataHistory.decode(history.encode());
    expect(loaded.batches.last.reversesBatchId, 'original');
    expect(loaded.batches.first.changes.single.after.value, 'Neu');
  });

  test('invalid retention limits and self-referencing undo are refused', () {
    final history = MetadataHistory();
    expect(
      () => history.append(batch('edit'), retainBatches: 0),
      throwsArgumentError,
    );
    expect(
      () => history.append(
        batch('edit'),
        byteBudget: MetadataHistory.maxBytes + 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => MetadataChangeBatch(
        id: 'same',
        source: 'user',
        at: at,
        reversesBatchId: 'same',
        changes: batch('sample').changes,
      ),
      throwsFormatException,
    );
    Object? nested = 'value';
    for (var i = 0; i < 18; i++) {
      nested = [nested];
    }
    expect(() => state(nested), throwsFormatException);
  });

  test('personal data is never an allowed metadata undo field', () {
    for (final field in [
      'progress',
      'position',
      'rating',
      'votes',
      'notes',
      'bookmarks',
      'device_id',
      'token',
      'offline_path',
    ]) {
      expect(
        () => change('work', field, 'A', 'B'),
        throwsFormatException,
        reason: field,
      );
    }
  });

  test(
    'unknown formats and malformed states are rejected, not treated as empty',
    () {
      for (final encoded in [
        '{}',
        '{"format_version":99,"batches":[]}',
        'not json',
      ]) {
        expect(() => MetadataHistory.decode(encoded), throwsFormatException);
      }
      expect(
        () => MetadataFieldState.fromJson({
          'present': true,
          'locked': false,
          'origin_at': 'bad',
        }),
        throwsFormatException,
      );
      expect(
        () => MetadataFieldState(present: false, value: 'unexpected'),
        throwsFormatException,
      );
      expect(() => state(double.nan), throwsFormatException);
      expect(
        () => state(List.filled(256 * 1024, 'long')),
        throwsFormatException,
      );
    },
  );
}
