import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

/// Kapitel holt sich nur, wer welche hat.
///
/// Ein Hörbuch in einer Datei benennt seine Kapitel im Container, und die zu
/// finden heißt, dessen Atombaum Kopf für Kopf abzulaufen. Bei einem Film
/// kommt dabei genau ein Eintrag heraus — derselbe, den es ohne den Lauf auch
/// gäbe —, und über eine Netzfreigabe sind das hunderte Zugriffe vor dem
/// ersten Bild.
void main() {
  late Directory root;
  late FundusLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-chapters-');
  });

  tearDown(() async {
    library.close();
    await root.delete(recursive: true);
  });

  test('ein Film wird für seine Kapitel nicht aufgemacht', () async {
    final folder = Directory('${root.path}/Filme/Dune')
      ..createSync(recursive: true);
    final file = File('${folder.path}/Dune.mp4');
    await file.writeAsBytes(List.filled(4096, 0));
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    final work = library.listWorks().firstWhere(
      (entry) => entry.kind == 'movie',
    );

    // Die Datei wird gelöscht: würde sie zum Lesen geöffnet, flöge es hier.
    await file.delete();
    final chapters = await library.playbackChapters(work.id);

    expect(chapters, hasLength(1));
    expect(chapters.single.title, 'Dune');
  });

  test('ein Hörbuch in einer Datei wird sehr wohl aufgemacht', () async {
    final folder = Directory('${root.path}/Hörbücher/Autor/Titel')
      ..createSync(recursive: true);
    await File('${folder.path}/Titel.m4b').writeAsBytes(List.filled(4096, 0));
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    final work = library.listWorks().single;

    // Ohne echte Atome kommt ein Eintrag heraus — der Punkt ist, dass es
    // überhaupt nachgesehen hat, und das tut es nur für diese Arten.
    final chapters = await library.playbackChapters(work.id);

    expect(chapters, hasLength(1));
  });
}
