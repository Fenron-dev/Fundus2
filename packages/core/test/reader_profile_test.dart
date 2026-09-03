import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-reader-profile-');
  });

  tearDown(() => root.delete(recursive: true));

  test('das Leseprofil überlebt eine Neuinstallation', () async {
    final library = await FundusLibrary.create(root);
    await library.saveReaderProfile(
      const PublicationReaderProfile(
        layout: PublicationReaderLayout.doublePage,
        readingDirection: PublicationReadingDirection.rightToLeft,
        pageScale: PublicationPageScale.fitHeight,
      ),
      workId: 'werk-1',
    );
    library.close();

    // Neue Installation, dieselbe Bibliothek.
    final reopened = await FundusLibrary.open(root);
    final profile = await reopened.loadReaderProfile(workId: 'werk-1');
    reopened.close();

    expect(profile.layout, PublicationReaderLayout.doublePage);
    expect(profile.readingDirection, PublicationReadingDirection.rightToLeft);
    expect(profile.pageScale, PublicationPageScale.fitHeight);
  });

  test('ein neues Werk erbt die zuletzt gewählte Einstellung', () async {
    final library = await FundusLibrary.create(root);
    await library.saveReaderProfile(
      const PublicationReaderProfile(layout: PublicationReaderLayout.webtoon),
      workId: 'werk-1',
    );

    final fresh = await library.loadReaderProfile(workId: 'werk-2');
    library.close();

    expect(fresh.layout, PublicationReaderLayout.webtoon);
  });

  test('ein Werk darf von der Vorgabe abweichen', () async {
    final library = await FundusLibrary.create(root);
    await library.saveReaderProfile(
      const PublicationReaderProfile(layout: PublicationReaderLayout.webtoon),
      workId: 'webtoon',
    );
    await library.saveReaderProfile(
      const PublicationReaderProfile(
        layout: PublicationReaderLayout.doublePage,
      ),
      workId: 'manga',
    );

    final webtoon = await library.loadReaderProfile(workId: 'webtoon');
    final manga = await library.loadReaderProfile(workId: 'manga');
    library.close();

    expect(webtoon.layout, PublicationReaderLayout.webtoon);
    expect(manga.layout, PublicationReaderLayout.doublePage);
  });

  test('ohne Profil gilt die Vorgabe, nicht ein Fehler', () async {
    final library = await FundusLibrary.create(root);
    final profile = await library.loadReaderProfile(workId: 'unbekannt');
    library.close();

    expect(profile.layout, PublicationReaderLayout.singlePage);
    expect(profile.readingDirection, PublicationReadingDirection.leftToRight);
  });

  test('eine unlesbare Datei kostet kein Buch', () async {
    final library = await FundusLibrary.create(root);
    final file = File('${root.path}/_fundus/readers/kaputt.json');
    await file.parent.create(recursive: true);
    await file.writeAsString('{ das ist kein JSON');

    final profile = await library.loadReaderProfile(workId: 'kaputt');
    library.close();

    expect(profile.layout, PublicationReaderLayout.singlePage);
  });
}
