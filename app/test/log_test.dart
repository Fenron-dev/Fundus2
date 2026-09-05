import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/fundus_log.dart';

/// Das Protokoll.
///
/// „Es ist langsam" ist ein Symptom. Was fehlte, war die Möglichkeit, das
/// weiterzugeben, woran man es festmachen kann — mit Dauer, und ohne dass
/// dabei der halbe Dateibaum mitgeht.
void main() {
  setUp(FundusLog.instance.clear);

  test('ein Eintrag trägt seine Dauer', () async {
    await FundusLog.instance.time('etwas', () async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }, {'was': 'test'});

    final entry = FundusLog.instance.entries.single;
    expect(entry.event, 'etwas');
    expect(entry.took, isNotNull);
    expect(entry.took!.inMilliseconds, greaterThanOrEqualTo(15));
    expect(entry.line, contains('was=test'));
  });

  test('ein Fehlschlag wird ebenfalls gemessen und weitergereicht', () async {
    await expectLater(
      FundusLog.instance.time('kaputt', () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw const FileSystemException('nichts da');
      }),
      throwsA(isA<FileSystemException>()),
    );

    final entry = FundusLog.instance.entries.single;
    expect(entry.level, LogLevel.error);
    expect(entry.took, isNotNull);
  });

  test('ein Abschnitt hält seine Zwischenschritte fest', () {
    final span = FundusLog.instance.start('öffnen', {'werk': 'Dune'});
    span.step('gefunden');
    span.done({'über': 'player'});

    final events = FundusLog.instance.entries
        .map((entry) => entry.event)
        .toList();
    expect(events, ['öffnen.gefunden', 'öffnen']);
    expect(FundusLog.instance.entries.last.line, contains('über=player'));
  });

  test('vollständige Pfade kommen nicht ins Protokoll', () {
    expect(
      FundusLog.where('/Volumes/Media/Fundus2-Vault/Filme/Dune/Dune.mkv'),
      '…/Dune/Dune.mkv',
    );
    expect(FundusLog.where('Dune.mkv'), 'Dune.mkv');
  });

  test('das Protokoll läuft nicht über', () {
    for (var index = 0; index < FundusLog.capacity + 50; index++) {
      FundusLog.instance.info('schritt', {'nummer': index});
    }

    expect(FundusLog.instance.entries, hasLength(FundusLog.capacity));
    expect(FundusLog.instance.entries.last.line, contains('nummer=649'));
  });

  test('abgeschaltet wird nichts aufgezeichnet', () {
    FundusLog.instance.setEnabled(false);
    addTearDown(() => FundusLog.instance.setEnabled(true));

    FundusLog.instance.info('nichts');

    expect(FundusLog.instance.entries, isEmpty);
  });
}
