import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus/features/work/metadata_dialog.dart';
import 'package:fundus/features/work/metadata_editor.dart';
import 'package:fundus/metadata/metadata_apply.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  group('Was ein Treffer zu sagen hat, wird angeboten', () {
    test('ein Feld, zu dem der Dienst schweigt, bekommt kein Häkchen', () {
      const sparse = MetadataCandidate(
        provider: 'audible',
        providerId: 'B1',
        title: 'Der Name des Windes',
      );

      final offered = offeredFields(sparse);
      expect(offered, contains(MetadataField.title));
      expect(offered, isNot(contains(MetadataField.description)));
      expect(offered, isNot(contains(MetadataField.cover)));
    });

    test('Reihe und Band stehen in einer Zeile', () {
      const candidate = MetadataCandidate(
        provider: 'audible',
        providerId: 'B1',
        title: 'Der Name des Windes',
        series: 'Königsmörder',
        seriesSequence: 1,
      );

      expect(offeredFields(candidate), contains(MetadataField.series));
      expect(
        matchValue(candidate, MetadataField.series),
        'Königsmörder · Band 1',
      );
    });
  });

  group('Eine Reihe lässt sich in einem Zug pflegen', () {
    late Directory root;
    late FundusLibrary library;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-serie-');
      for (final band in ['Band 1', 'Band 2']) {
        final folder = Directory('${root.path}/Hörbücher/Königsmörder/$band')
          ..createSync(recursive: true);
        await File('${folder.path}/01.m4b').writeAsBytes(List.filled(64, 1));
      }
      library = await FundusLibrary.create(root);
      await library.index().drain<void>();
      for (final work in library.listWorks()) {
        await library.updateWorkMetadata(
          workId: work.id,
          title: work.title,
          authors: const ['Unbekannt'],
          series: 'Königsmörder',
        );
      }
    });

    tearDown(() async {
      library.close();
      await root.delete(recursive: true);
    });

    test('die anderen Bände findet man über den Reihennamen', () {
      final works = library.listWorks();
      final siblings = seriesSiblings(
        works,
        workId: works.first.id,
        series: 'königsmörder ',
      );

      expect(siblings.map((work) => work.id), [works.last.id]);
      // Das bearbeitete Werk ist nie sein eigener Nachbar.
      expect(siblings.map((work) => work.id), isNot(contains(works.first.id)));
    });

    test('ohne Reihe gibt es nichts zu verteilen', () {
      final works = library.listWorks();
      expect(
        seriesSiblings(works, workId: works.first.id, series: null),
        isEmpty,
      );
      expect(
        seriesSiblings(works, workId: works.first.id, series: '  '),
        isEmpty,
      );
    });

    test('geteilt wird der Urheber, nicht der Titel', () async {
      final works = library.listWorks();
      final sibling = works.last;

      await applySharedFields(
        library: library,
        work: sibling,
        authors: const ['Patrick Rothfuss'],
        series: 'Die Königsmörder-Chronik',
        publisher: 'Random House Audio',
        language: 'de',
        genres: const ['Fantasy'],
      );

      final updated = library.listWorks().firstWhere(
        (work) => work.id == sibling.id,
      );
      expect(updated.author, 'Patrick Rothfuss');
      expect(updated.series, 'Die Königsmörder-Chronik');
      expect(updated.publisher, 'Random House Audio');
      expect(updated.genres, ['Fantasy']);
      // Der Titel des Bandes bleibt seiner.
      expect(updated.title, sibling.title);
    });
  });

  group('Was jetzt dasteht, wird beim Übernehmen gezeigt', () {
    late Directory root;
    late FundusLibrary library;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fundus-jetzt-');
      final folder = Directory('${root.path}/Hörbücher/Wind')
        ..createSync(recursive: true);
      await File('${folder.path}/01.m4b').writeAsBytes(List.filled(64, 1));
      library = await FundusLibrary.create(root);
      await library.index().drain<void>();
    });

    tearDown(() async {
      library.close();
      await root.delete(recursive: true);
    });

    test('ein leeres Feld sagt nichts, ein gefülltes seinen Wert', () async {
      final work = WorkView.fromSummary(library.listWorks().single);
      expect(currentValue(work, MetadataField.publisher), '');

      await library.updateWorkMetadata(
        workId: work.id,
        title: 'Wind',
        authors: const ['Patrick Rothfuss'],
        publisher: 'Random House Audio',
      );

      final saved = WorkView.fromSummary(library.listWorks().single);
      expect(
        currentValue(saved, MetadataField.publisher),
        'Random House Audio',
      );
      expect(currentValue(saved, MetadataField.authors), 'Patrick Rothfuss');
    });
  });
}
