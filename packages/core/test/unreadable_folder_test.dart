import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

/// Ein Ordner, der sich nicht öffnen lässt, beweist nichts.
///
/// Der Durchgang markiert alles als fehlend, was er nicht angetroffen hat. Auf
/// einer Netzfreigabe verweigert ein Ordner hin und wieder die Auskunft — und
/// ein einziger solcher Aussetzer hat einem Werk sein Cover genommen: die
/// Datei war da, der Lauf ist nur nie hingekommen.
///
/// Der Scanner, den dieser Test einsetzt, verweigert genau einen Ordner.
final class StubbornScanner extends LibraryScanner {
  StubbornScanner(this.refuses);

  /// Der Pfad relativ zur Wurzel, der sich nicht lesen lässt.
  final String refuses;

  @override
  Stream<ScanEvent> scan(
    Directory root, {
    ScanCancellationToken? cancellationToken,
    ScannedFileStamp? isUnchanged,
    String? subtree,
  }) async* {
    final refused = '${root.absolute.path}/$refuses';
    var visited = 0;
    await for (final event in super.scan(
      root,
      cancellationToken: cancellationToken,
      isUnchanged: isUnchanged,
      subtree: subtree,
    )) {
      final path = event.file?.absolutePath;
      if (path != null && path.startsWith('$refused/')) continue;
      if (event.kind == ScanEventKind.file) visited++;
      yield event;
    }
    yield ScanEvent(
      kind: ScanEventKind.error,
      visitedFiles: visited,
      path: refused,
      error: const FileSystemException('Freigabe antwortet nicht.'),
    );
  }
}

void main() {
  test('was in einem unlesbaren Ordner liegt, bleibt vorhanden', () async {
    final root = await Directory.systemTemp.createTemp('fundus-unreadable-');
    addTearDown(() => root.delete(recursive: true));
    for (final title in ['About Time', 'I Am Legend']) {
      final folder = Directory('${root.path}/Filme/$title')
        ..createSync(recursive: true);
      await File('${folder.path}/$title.mkv').writeAsBytes(List.filled(64, 1));
      await File('${folder.path}/$title.jpg').writeAsBytes(List.filled(32, 2));
    }
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();

    final before = library.listWorks();
    expect(before, hasLength(2));
    expect(before.every((work) => work.coverPath != null), isTrue);

    // Derselbe Bestand, aber ein Ordner antwortet nicht mehr.
    final event =
        (await library
                .index(scanner: StubbornScanner('Filme/About Time'))
                .toList())
            .last;

    expect(event.unreadableFolders, contains('Filme/About Time'));
    final after = library.listWorks();
    expect(after, hasLength(2), reason: 'nichts ist verschwunden');
    expect(
      after.firstWhere((work) => work.title == 'About Time').coverPath,
      isNotNull,
      reason: 'und das Cover ist noch da',
    );
    expect(
      after.firstWhere((work) => work.title == 'About Time').status,
      'available',
    );
  });

  test('was wirklich gelöscht wurde, wird auch als fehlend geführt', () async {
    final root = await Directory.systemTemp.createTemp('fundus-gone-');
    addTearDown(() => root.delete(recursive: true));
    final folder = Directory('${root.path}/Filme/About Time')
      ..createSync(recursive: true);
    await File('${folder.path}/About Time.mkv').writeAsBytes([1]);
    await File('${folder.path}/About Time.jpg').writeAsBytes([2]);
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();
    expect(library.listWorks().single.coverPath, isNotNull);

    await File('${folder.path}/About Time.jpg').delete();
    await library.index().drain<void>();

    expect(library.listWorks().single.coverPath, isNull);
  });
}
