import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Rollen sind Daten, keine Fallunterscheidung.
void main() {
  late Directory root;
  late FundusLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-rollen-');
    library = await FundusLibrary.create(root);
  });

  tearDown(() async {
    library.close();
    await root.delete(recursive: true);
  });

  test('eine frische Bibliothek kennt die gängigen Rollen', () {
    final namen = library.listPersonRoles().map((role) => role.name);
    expect(
      namen,
      containsAll(['Darsteller', 'Regie', 'Drehbuch', 'Autor', 'Sprecher']),
    );
  });

  group('Zuordnung', () {
    test('verschiedene Schreibweisen landen unter einer Überschrift', () {
      final rollen = library.listPersonRoles();
      for (final geschickt in ['Actor', 'actress', 'Cast', 'Darsteller']) {
        expect(
          personRoleLabel(geschickt, rollen),
          'Darsteller',
          reason: '„$geschickt" ist dasselbe',
        );
      }
    });

    test('die Figur bleibt an der Person, macht aber keine eigene Zeile', () {
      // TMDB hängt den Namen der Figur an: „Darsteller · Jack".
      expect(
        personRoleLabel('Darsteller · Jack', library.listPersonRoles()),
        'Darsteller',
      );
    });

    test('ein zusammengesetzter Anbieterbegriff wird erkannt', () {
      expect(
        personRoleLabel('Directing · Director', library.listPersonRoles()),
        'Regie',
      );
    });

    test('was keine Rolle trifft, bleibt stehen wie es kam', () {
      // Ehrlicher als ein Sammeltopf — und der Hinweis, welche Schreibweise
      // noch fehlt.
      expect(
        personRoleLabel('Key Animation', library.listPersonRoles()),
        'Key Animation',
      );
    });

    test('ohne Rollen bleibt alles, wie es kam', () {
      expect(personRoleLabel('Actor', const []), 'Actor');
    });
  });

  group('Verwalten', () {
    test('eine Schreibweise ergänzen führt zusammen', () async {
      expect(
        personRoleLabel('Key Animation', library.listPersonRoles()),
        'Key Animation',
      );
      final zeichnung = library.listPersonRoles().firstWhere(
        (role) => role.name == 'Zeichnung',
      );
      await library.savePersonRole(
        id: zeichnung.id,
        name: zeichnung.name,
        aliases: [...zeichnung.aliases, 'key animation'],
      );
      expect(
        personRoleLabel('Key Animation', library.listPersonRoles()),
        'Zeichnung',
      );
    });

    test('umbenennen benennt überall um', () async {
      final regie = library.listPersonRoles().firstWhere(
        (role) => role.name == 'Regie',
      );
      await library.savePersonRole(
        id: regie.id,
        name: 'Regie & Leitung',
        aliases: regie.aliases,
      );
      expect(
        personRoleLabel('Director', library.listPersonRoles()),
        'Regie & Leitung',
      );
      expect(
        library.listPersonRoles().where((role) => role.name == 'Regie'),
        isEmpty,
      );
    });

    test('auf einen vorhandenen Namen umbenennen führt zusammen', () async {
      // Zwei Rollen, die dasselbe meinen, sind der Normalfall, wenn zwei
      // Anbieter sie verschieden nennen.
      final vorher = library.listPersonRoles().length;
      final drehbuch = library.listPersonRoles().firstWhere(
        (role) => role.name == 'Drehbuch',
      );
      await library.savePersonRole(
        id: drehbuch.id,
        name: 'Autor',
        aliases: const ['drehbuch', 'author'],
      );
      final nachher = library.listPersonRoles();
      expect(nachher, hasLength(vorher - 1));
      expect(nachher.where((role) => role.name == 'Autor'), hasLength(1));
      expect(personRoleLabel('Drehbuch', nachher), 'Autor');
    });

    test('eine eigene Rolle lässt sich anlegen', () async {
      await library.savePersonRole(
        name: 'Lektorat',
        aliases: const ['editor', 'lektorat'],
      );
      expect(personRoleLabel('Editor', library.listPersonRoles()), 'Lektorat');
    });

    test('löschen lässt die Bezeichnung zurückfallen', () async {
      final sprecher = library.listPersonRoles().firstWhere(
        (role) => role.name == 'Sprecher',
      );
      await library.deletePersonRole(sprecher.id);
      // Die Besetzung an den Werken bleibt; sie erscheint wieder unter ihrer
      // eigenen Bezeichnung, statt zu verschwinden.
      expect(
        personRoleLabel('Narrator', library.listPersonRoles()),
        'Narrator',
      );
    });

    test('eine Rolle ohne Namen wird abgewiesen', () async {
      await expectLater(
        library.savePersonRole(name: '   '),
        throwsArgumentError,
      );
    });
  });

  test('schema v17 bekommt die Rollen nachgereicht', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-db-v17-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/index.db');
    final legacy = sqlite3.open(file.path);
    legacy.execute('CREATE TABLE works (id TEXT PRIMARY KEY)');
    legacy.userVersion = 17;
    legacy.close();

    final migrated = FundusDatabase.openFile(file);
    addTearDown(migrated.close);
    expect(migrated.userVersion, FundusDatabase.schemaVersion);
    expect(
      migrated.listPersonRoles().map((role) => role.name),
      contains('Darsteller'),
    );
  });
}
