import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/media/comic_archive.dart';
import 'package:path/path.dart' as p;

/// Der Ort für Seiten, die nur für diese Sitzung entstehen.
///
/// Aus dem Betrieb: „PDF öffnen" endete auf beiden Geräten mit
/// PathNotFoundException — in der Sandbox zeigt der Ort für Temporäres auf
/// einen Ordner, den es noch nicht gibt.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-kritzel-');
  });

  tearDown(() => root.delete(recursive: true));

  test('der Ordner entsteht, auch wenn sein Elternteil fehlt', () {
    final missing = Directory(p.join(root.path, 'Data', 'tmp'));
    expect(missing.existsSync(), isFalse);

    final scratch = scratchDirectory('fundus-pdf-pages', under: missing);

    expect(scratch.existsSync(), isTrue);
    // Und genau das war der Schritt, der vorher scheiterte.
    final pages = scratch.createTempSync('pages-');
    expect(pages.existsSync(), isTrue);
  });

  test('ein Ordner, den es schon gibt, bleibt', () {
    final first = scratchDirectory('fundus-pdf-pages', under: root);
    File(p.join(first.path, 'merkmal')).writeAsStringSync('da');

    final again = scratchDirectory('fundus-pdf-pages', under: root);

    expect(again.path, first.path);
    expect(File(p.join(again.path, 'merkmal')).existsSync(), isTrue);
  });
}
