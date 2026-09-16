import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

/// Eigenschaften, die jemand selbst anlegt — und was davon geschützt ist.
void main() {
  late Directory root;
  late FundusLibrary library;
  late LibraryWorkSummary offen;
  late LibraryWorkSummary geschuetzt;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-eigenschaften-');
    for (final title in ['Klingenwind', 'Nachtschatten']) {
      final work = Directory('${root.path}/Manga/$title');
      await work.create(recursive: true);
      await File('${work.path}/01.cbz').writeAsBytes(List.filled(64, 1));
    }
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    final works = library.listWorks()
      ..sort((a, b) => a.title.compareTo(b.title));
    offen = works.first;
    geschuetzt = works.last;
    await library.updateWorkMetadata(
      workId: geschuetzt.id,
      title: geschuetzt.title,
      authors: geschuetzt.authors,
      contentSensitivity: 'adult_explicit',
    );
  });

  tearDown(() async {
    library.close();
    await root.delete(recursive: true);
  });

  group('Definitionen', () {
    test('eine Eigenschaft wird angelegt und wiedergefunden', () async {
      final definition = await library.savePropertyDefinition(
        mediaKind: 'manga',
        name: 'Erscheinungsland',
        valueType: PropertyValueType.text,
      );
      expect(library.listPropertyDefinitions(mediaKind: 'manga'), [
        isA<WorkPropertyDefinition>().having(
          (it) => it.id,
          'Kennung',
          definition.id,
        ),
      ]);
    });

    test('derselbe Name zweimal ändert, statt zu verdoppeln', () async {
      final erst = await library.savePropertyDefinition(
        mediaKind: 'manga',
        name: 'Bewertung',
        valueType: PropertyValueType.text,
      );
      final dann = await library.savePropertyDefinition(
        mediaKind: 'manga',
        name: 'Bewertung',
        valueType: PropertyValueType.rating,
      );
      expect(dann.id, erst.id);
      expect(library.listPropertyDefinitions(mediaKind: 'manga'), hasLength(1));
      expect(
        library.listPropertyDefinitions().single.valueType,
        PropertyValueType.rating,
      );
    });

    test('eine Eigenschaft ohne Medienart gilt überall', () async {
      await library.savePropertyDefinition(
        mediaKind: '',
        name: 'Gekauft bei',
        valueType: PropertyValueType.link,
      );
      expect(library.listPropertyDefinitions(mediaKind: 'manga'), hasLength(1));
      expect(library.listPropertyDefinitions(mediaKind: 'anime'), hasLength(1));
    });

    test('löschen nimmt die Werte mit', () async {
      final definition = await library.savePropertyDefinition(
        mediaKind: 'manga',
        name: 'Regal',
        valueType: PropertyValueType.text,
      );
      await library.setWorkProperty(
        workId: offen.id,
        definitionId: definition.id,
        value: 'Oben links',
      );
      expect(library.loadWorkProperties(offen.id), hasLength(1));

      await library.deletePropertyDefinition(definition.id);
      expect(
        library.loadWorkProperties(offen.id),
        isEmpty,
        reason: 'ein Wert ohne Definition wäre eine unlesbare Zeile',
      );
    });
  });

  group('Werte', () {
    test('ein Wert muss zu seinem Typ passen', () async {
      final bewertung = await library.savePropertyDefinition(
        mediaKind: 'manga',
        name: 'Bewertung',
        valueType: PropertyValueType.rating,
      );
      await library.setWorkProperty(
        workId: offen.id,
        definitionId: bewertung.id,
        value: 4,
      );
      expect(library.loadWorkProperties(offen.id)[bewertung.id]?.value, 4);

      // Eine Datenbank, in der eine Bewertung als Zeichenkette steht, macht
      // jede spätere Sortierung zu einem Sonderfall.
      await expectLater(
        library.setWorkProperty(
          workId: offen.id,
          definitionId: bewertung.id,
          value: 'sehr gut',
        ),
        throwsArgumentError,
      );
      await expectLater(
        library.setWorkProperty(
          workId: offen.id,
          definitionId: bewertung.id,
          value: 9,
        ),
        throwsArgumentError,
      );
    });

    test('Listen und Daten werden als das gelesen, was sie sind', () async {
      final gelesen = await library.savePropertyDefinition(
        mediaKind: 'manga',
        name: 'Gelesen am',
        valueType: PropertyValueType.date,
      );
      final leute = await library.savePropertyDefinition(
        mediaKind: 'manga',
        name: 'Empfohlen von',
        valueType: PropertyValueType.list,
      );
      await library.setWorkProperty(
        workId: offen.id,
        definitionId: gelesen.id,
        value: '2026-09-16',
      );
      await library.setWorkProperty(
        workId: offen.id,
        definitionId: leute.id,
        value: const ['Birthe', 'Karl'],
      );
      final werte = library.loadWorkProperties(offen.id);
      expect(werte[gelesen.id]?.value, '2026-09-16');
      expect(werte[leute.id]?.value, ['Birthe', 'Karl']);
    });

    test('null nimmt den Wert weg', () async {
      final regal = await library.savePropertyDefinition(
        mediaKind: 'manga',
        name: 'Regal',
        valueType: PropertyValueType.text,
      );
      await library.setWorkProperty(
        workId: offen.id,
        definitionId: regal.id,
        value: 'Oben',
      );
      await library.setWorkProperty(
        workId: offen.id,
        definitionId: regal.id,
        value: null,
      );
      expect(library.loadWorkProperties(offen.id), isEmpty);
    });
  });

  group('Was geschützt ist, steht nicht zur Auswahl', () {
    test('ein ausdrücklich gekennzeichnetes Schlagwort verschwindet', () async {
      await library.replaceWorkTags(offen.id, ['Shōnen', 'Doujin']);
      expect(library.listTags(), containsAll(['Shōnen', 'Doujin']));

      await library.setTagProtected('Doujin', protected: true);
      expect(library.listTags(), contains('Shōnen'));
      expect(library.listTags(), isNot(contains('Doujin')));
      expect(library.listTags(includeProtected: true), contains('Doujin'));
      expect(library.isTagProtected('Doujin'), isTrue);
    });

    test(
      'ein Wort nur an geschützten Werken gilt selbst als geschützt',
      () async {
        // Das Netz unter dem Kennzeichen: kennzeichnen muss man daran denken,
        // und bei einer gewachsenen Sammlung denkt niemand an alles.
        await library.replaceWorkTags(geschuetzt.id, ['Nur hier']);
        await library.replaceWorkTags(offen.id, ['Auch woanders']);

        expect(library.listTags(), contains('Auch woanders'));
        expect(library.listTags(), isNot(contains('Nur hier')));
        expect(library.isTagProtected('Nur hier'), isTrue);
        expect(library.isTagProtected('Auch woanders'), isFalse);
      },
    );

    test('dasselbe Wort an beiden bleibt sichtbar', () async {
      // Sonst verschwände „Fantasy", sobald ein einziges geschütztes Werk es
      // trägt — und mit ihm die halbe Bibliothek aus dem Filter.
      await library.replaceWorkTags(geschuetzt.id, ['Fantasy']);
      await library.replaceWorkTags(offen.id, ['Fantasy']);
      expect(library.listTags(), contains('Fantasy'));
      expect(library.isTagProtected('Fantasy'), isFalse);
    });

    test('eine geschützte Eigenschaft steht nicht in der Auswahl', () async {
      await library.savePropertyDefinition(
        mediaKind: 'manga',
        name: 'Seitenzahl',
        valueType: PropertyValueType.number,
      );
      await library.savePropertyDefinition(
        mediaKind: 'manga',
        name: 'Verrät zu viel',
        valueType: PropertyValueType.text,
        protected: true,
      );
      expect(
        library
            .listPropertyDefinitions(
              mediaKind: 'manga',
              includeProtected: false,
            )
            .map((it) => it.name),
        ['Seitenzahl'],
      );
      expect(library.listPropertyDefinitions(mediaKind: 'manga'), hasLength(2));
    });
  });
}
