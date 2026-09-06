import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Das Cover ist, wie ein Werk aussieht — nicht, was es ist.
///
/// Aus dem Betrieb: neben dem Band stand im Reiter „Dateien" auch das
/// Coverbild, und bei Webnovels ebenso.
void main() {
  late Directory root;
  late FundusLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-cover-');
  });

  tearDown(() async {
    library.close();
    await root.delete(recursive: true);
  });

  Future<void> index() async {
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
  }

  Future<void> put(String path, [List<int> bytes = const [1, 2, 3]]) async {
    final file = File(p.join(root.path, path));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  test('ein Buch besteht aus dem Buch, nicht aus Buch und Bild', () async {
    await put('Bücher/Ursula K. Le Guin/Erdsee/Erdsee.epub');
    await put('Bücher/Ursula K. Le Guin/Erdsee/cover.jpg');
    await index();

    final work = library.listWorks().single;
    expect(work.kind, 'ebook');
    expect(work.coverPath, endsWith('cover.jpg'));
    expect(library.playbackTracks(work.id).map((file) => file.title), [
      'Erdsee.epub',
    ]);
    expect(library.contentFiles(work.id).map((file) => file.filename), [
      'Erdsee.epub',
    ]);
  });

  test('ein Webnovel ebenso', () async {
    await put('Webnovels/Der Schacht/Kapitel 1.txt');
    await put('Webnovels/Der Schacht/Kapitel 2.txt');
    await put('Webnovels/Der Schacht/cover.png');
    await index();

    final work = library.listWorks().single;
    expect(library.playbackTracks(work.id).map((file) => file.title), [
      'Kapitel 1.txt',
      'Kapitel 2.txt',
    ]);
  });

  test('eine Galerie behält jedes ihrer Bilder', () async {
    await put('Fotos/Nordsee 2024/01.jpg');
    await put('Fotos/Nordsee 2024/02.jpg');
    await index();

    final work = library.listWorks().single;
    // Hier ist das Titelbild wirklich eine Seite.
    expect(library.contentFiles(work.id), hasLength(2));
  });

  test('ein Werk, das nur sein Bild hat, behält es', () async {
    await put('Bücher/Skizzen/nur-ein-bild.jpg');
    await index();

    final work = library.listWorks().single;
    expect(library.contentFiles(work.id), hasLength(1));
  });
}
