import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/media_type.dart';
import 'package:fundus/data/work_filter.dart';

/// Der Ordner-Tab zeigt, wo etwas liegt.
///
/// Vorher wurde der Ordner aus dem Pfad des Titelbilds abgelesen — ein Werk
/// mit geholtem Bild landete damit unter „covers", eines ohne Bild unter
/// „Bibliothekswurzel", egal wo es tatsächlich lag.
void main() {
  late Directory root;
  late LibraryController library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-folder-');
    final show = Directory('${root.path}/Podcasts/Auf ein Bier')
      ..createSync(recursive: true);
    File('${show.path}/Folge 1.mp3').writeAsBytesSync(List.filled(64, 1));
    final other = Directory('${root.path}/Hörbücher/Karl May/Der Schacht')
      ..createSync(recursive: true);
    File('${other.path}/01.mp3').writeAsBytesSync(List.filled(64, 1));
    library = LibraryController();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  test('gruppiert wird nach dem Weg in der Bibliothek', () async {
    await library.open(root, createIfMissing: true);
    await library.scan();

    final groups = WorkGrouping.group(library.works, GroupingMode.folder);
    final labels = groups.map((group) => group.label).toList();

    expect(labels, contains('Podcasts'));
    expect(labels, contains('Hörbücher/Karl May'));
    expect(labels, isNot(contains('covers')));
    expect(labels, isNot(contains('Bibliothekswurzel')));
  });
}
