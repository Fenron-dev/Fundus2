import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Aus Namen in den Metadaten werden Personen.
///
/// Urheber und Sprecher standen nur als Zeichenketten in `metadata_json`. Die
/// Werkseite half sich damit, sie ersatzweise anzuzeigen — eine Person war das
/// aber nicht: kein Bild, keine Rolle, keine eigene Seite.
void main() {
  late Directory root;
  late FundusLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-personen-');
    final book = Directory('${root.path}/Hörbücher/Karl May/Winnetou');
    await book.create(recursive: true);
    await File('${book.path}/01 - Kapitel.mp3').writeAsBytes([1, 2, 3]);
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
  });

  tearDown(() async {
    library.close();
    await root.delete(recursive: true);
  });

  test('der Autor aus dem Ordnernamen wird eine Person', () {
    final werk = library.listWorks().single;
    final beteiligte = library.peopleOf(werk.id);
    expect(beteiligte, isNotEmpty);
    expect(beteiligte.map((person) => person.name), contains('Karl May'));
    expect(
      beteiligte.firstWhere((person) => person.name == 'Karl May').role,
      'Autor',
    );
  });

  test('„Unbekannt" wird keine Person', () async {
    // Der Import setzt das, wo nichts dasteht. Eine Personenseite dafür wäre
    // eine Seite über nichts.
    final werk = library.listWorks().single;
    await library.updateWorkMetadata(
      workId: werk.id,
      title: werk.title,
      authors: const ['Unbekannt'],
    );
    expect(
      library.peopleOf(werk.id).map((person) => person.name),
      isNot(contains('Unbekannt')),
    );
  });

  test('Sprecher bekommen ihre eigene Rolle', () async {
    final werk = library.listWorks().single;
    await library.updateWorkMetadata(
      workId: werk.id,
      title: werk.title,
      authors: const ['Karl May'],
      narrators: const ['Marit Sölden'],
    );
    final beteiligte = library.peopleOf(werk.id);
    expect(
      beteiligte.firstWhere((person) => person.name == 'Marit Sölden').role,
      'Sprecher',
    );
  });

  test('Personenprofile speichern Notizen und externe Kennungen', () {
    final work = library.listWorks().single;
    final person = library.peopleOf(work.id).single.name;
    library.savePersonProfile(
      currentName: person,
      displayName: 'Karl May (Autor)',
      notes: 'Schreibt Abenteuerromane.',
      externalIds: const {'wikidata': 'Q123'},
    );
    final profile = library.personProfile('Karl May (Autor)');
    expect(profile?.notes, 'Schreibt Abenteuerromane.');
    expect(profile?.externalIds['wikidata'], 'Q123');
    expect(library.peopleOf(work.id).single.name, 'Karl May (Autor)');
  });

  test('eine Besetzung vom Abgleich wird nicht überschrieben', () async {
    // Sie ist genauer und hat Gesichter; was aus einem Dateinamen abgeleitet
    // ist, darf sie nicht verdrängen.
    final werk = library.listWorks().single;
    library.replaceWorkPeople(werk.id, [
      (name: 'Echte Besetzung', role: 'Darsteller', imagePath: null),
    ]);
    await library.updateWorkMetadata(
      workId: werk.id,
      title: werk.title,
      authors: const ['Karl May'],
    );

    final namen = library.peopleOf(werk.id).map((person) => person.name);
    expect(namen, ['Echte Besetzung']);
    expect(namen, isNot(contains('Karl May')));
  });

  test('geänderte Metadaten ersetzen die abgeleiteten Personen', () async {
    final werk = library.listWorks().single;
    await library.updateWorkMetadata(
      workId: werk.id,
      title: werk.title,
      authors: const ['Neuer Name'],
    );
    final namen = library.peopleOf(werk.id).map((person) => person.name);
    expect(namen, contains('Neuer Name'));
    expect(namen, isNot(contains('Karl May')));
  });

  test('schema v18 bekommt die Herkunftsspalte', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-db-v18-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/index.db');
    final legacy = sqlite3.open(file.path);
    legacy.execute('CREATE TABLE works (id TEXT PRIMARY KEY)');
    legacy.execute('CREATE TABLE people (id TEXT PRIMARY KEY)');
    legacy.execute(
      'CREATE TABLE work_people (work_id TEXT NOT NULL, '
      'person_id TEXT NOT NULL, role TEXT NOT NULL, '
      'position INTEGER NOT NULL DEFAULT 0, '
      'PRIMARY KEY (work_id, person_id, role))',
    );
    legacy.userVersion = 18;
    legacy.close();

    final migrated = FundusDatabase.openFile(file);
    addTearDown(migrated.close);
    expect(migrated.userVersion, FundusDatabase.schemaVersion);
    expect(migrated.columnExists('work_people', 'source'), isTrue);
  });
}
