import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/library_controller.dart';

/// A folder that does not answer.
///
/// A vault on a network share that is not mounted does not fail — it blocks,
/// in a native call, for as long as the system feels like. Waiting forever
/// looks exactly like working, which is the worst thing an opening library
/// can look like.
void main() {
  late LibraryController library;

  setUp(() => library = LibraryController());
  tearDown(() => library.dispose());

  test('ein Ordner, den es nicht gibt, wird gemeldet statt gewartet', () async {
    final started = DateTime.now();

    await library.open(Directory('/gibt-es-nicht/Fundus'));

    expect(library.status, LibraryStatus.failed);
    expect(library.isOpen, isFalse);
    // Und zwar zügig: die Grenze ist die Wartezeit, nicht die Geduld.
    expect(
      DateTime.now().difference(started),
      lessThan(LibraryController.reachTimeout * 2),
    );
  });

  test('die Meldung nennt den Pfad und den wahrscheinlichen Grund', () async {
    await library.open(Directory('/Volumes/NichtVerbunden/Fundus'));

    expect(library.error, contains('/Volumes/NichtVerbunden/Fundus'));
    expect(library.error, contains('Netzfreigabe'));
  });

  test('ein erreichbarer Ordner geht wie immer auf', () async {
    final root = await Directory.systemTemp.createTemp('fundus-reach-');
    addTearDown(() => root.delete(recursive: true));

    await library.open(root, createIfMissing: true);

    expect(library.status, LibraryStatus.ready);
    expect(library.isOpen, isTrue);
  });
}
