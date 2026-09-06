import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Was die Wartungsseite anzeigt, muss die Bibliothek auch sagen können.
void main() {
  late Directory root;
  late FundusLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-wartung-');
    final music = Directory(p.join(root.path, 'Musik', 'Kraftwerk', 'Autobahn'))
      ..createSync(recursive: true);
    for (var track = 1; track <= 3; track++) {
      await File(
        p.join(music.path, '0$track.mp3'),
      ).writeAsBytes(List.filled(1000 * track, 1));
    }
    final film = Directory(p.join(root.path, 'Filme', 'Nordwind (2019)'))
      ..createSync(recursive: true);
    await File(
      p.join(film.path, 'Nordwind (2019).mkv'),
    ).writeAsBytes(List.filled(9000, 2));

    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
  });

  tearDown(() async {
    library.close();
    await root.delete(recursive: true);
  });

  test('der Bestand wird nach Art aufgeteilt', () {
    final groups = library.storageByKind();

    expect(groups, isNotEmpty);
    final total = groups.fold(0, (sum, group) => sum + group.bytes);
    expect(total, 1000 + 2000 + 3000 + 9000);
    // Die größte Art steht vorn.
    expect(groups.first.bytes, 9000);
    expect(groups.map((group) => group.files).reduce((a, b) => a + b), 4);
  });

  test('verwaiste Einträge werden gezählt und weggeräumt', () async {
    expect(library.orphanCount().missingFiles, 0);

    // Ein Album verschwindet außerhalb von Fundus.
    await Directory(
      p.join(root.path, 'Musik', 'Kraftwerk', 'Autobahn'),
    ).delete(recursive: true);
    await library.index().drain<void>();

    final before = library.orphanCount();
    expect(before.missingFiles, 3);

    final removed = library.removeOrphans();

    expect(removed.files, 3);
    expect(removed.works, greaterThan(0));
    expect(library.orphanCount().missingFiles, 0);
    expect(library.orphanCount().emptyWorks, 0);
    // Der Film bleibt, wo er ist.
    expect(
      library.listWorks().map((work) => work.title),
      contains('Nordwind (2019)'),
    );
  });

  test('die Katalogdatei lässt sich verdichten', () {
    final size = library.catalogueBytes();
    expect(size, greaterThan(0));

    final result = library.compactCatalogue();

    expect(result.before, greaterThan(0));
    expect(result.after, greaterThan(0));
    expect(result.after, lessThanOrEqualTo(result.before));
  });
}
