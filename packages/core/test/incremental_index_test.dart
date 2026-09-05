import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  Future<Directory> vault() async {
    final root = await Directory.systemTemp.createTemp('fundus-delta-');
    addTearDown(() => root.delete(recursive: true));
    return root;
  }

  Future<void> book(Directory root, String path, {int chapters = 2}) async {
    final directory = Directory('${root.path}/$path');
    await directory.create(recursive: true);
    for (var index = 1; index <= chapters; index++) {
      await File(
        '${directory.path}/0$index - Kapitel.mp3',
      ).writeAsBytes(List.filled(index * 3, index));
    }
  }

  test('ein zweiter Durchgang ohne Änderung schreibt nichts neu', () async {
    final root = await vault();
    await book(root, 'Hörbücher/Karl May/Winnetou/01 - Winnetou I');
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);

    await library.index().toList();
    final second = (await library.index().toList()).last;

    expect(second.phase, LibraryIndexPhase.completed);
    expect(second.fileCount, 2, reason: 'die Dateien werden weiter gezählt');
    expect(second.workCount, 1);
    expect(second.changedFileCount, 0);
    expect(second.changedWorkCount, 0);
    expect(library.listWorks(), hasLength(1));
  });

  test('ein neues Werk kostet nur dieses Werk', () async {
    final root = await vault();
    await book(root, 'Hörbücher/Karl May/Winnetou/01 - Winnetou I');
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().toList();

    await book(root, 'Hörbücher/Karl May/Winnetou/02 - Winnetou II');
    final second = (await library.index().toList()).last;

    expect(second.changedWorkCount, 1);
    expect(second.workCount, 2);
    expect(library.listWorks(), hasLength(2));
  });

  test('eine verschwundene Datei macht ihr Werk wieder schmutzig', () async {
    final root = await vault();
    await book(root, 'Hörbücher/Karl May/Winnetou/01 - Winnetou I');
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().toList();

    await File(
      '${root.path}/Hörbücher/Karl May/Winnetou/01 - Winnetou I/'
      '02 - Kapitel.mp3',
    ).delete();
    final second = (await library.index().toList()).last;

    expect(second.changedWorkCount, 1);
    expect(library.listWorks().single.fileCount, 1);
  });

  test('ein Teillauf urteilt nicht über den Rest der Bibliothek', () async {
    final root = await vault();
    await book(root, 'Hörbücher/Karl May/Winnetou/01 - Winnetou I');
    await book(root, 'Hörbücher/Anderer/Reihe/01 - Titel');
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().toList();

    final partial =
        (await library.index(subtree: 'Hörbücher/Karl May').toList()).last;

    expect(partial.phase, LibraryIndexPhase.completed);
    expect(partial.fileCount, 2);
    expect(
      library.listWorks(), //
      hasLength(2),
      reason: 'das ungeprüfte Werk bleibt vorhanden',
    );
    expect(
      library.listWorks().where((work) => work.fileCount == 0),
      isEmpty,
      reason: 'und behält seine Dateien',
    );
  });

  test('ein voller Durchgang liest alles wieder ein', () async {
    final root = await vault();
    await book(root, 'Hörbücher/Karl May/Winnetou/01 - Winnetou I');
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().toList();

    final again = (await library.index(full: true).toList()).last;

    expect(again.changedWorkCount, 1);
    expect(again.changedFileCount, 2);
  });
}
