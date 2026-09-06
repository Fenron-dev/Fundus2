import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('scanner streams portable paths and ignores Fundus internals', () async {
    final root = await Directory.systemTemp.createTemp('fundus-scanner-');
    addTearDown(() => root.delete(recursive: true));

    final book = Directory(p.join(root.path, 'Autor', 'Serie', '01 - Titel'));
    await book.create(recursive: true);
    await File(
      p.join(book.path, '01 - Anfang.mp3'),
    ).writeAsBytes([0xff, 0xfb, 0x90, 0x64, ...List.filled(16, 0)]);
    await File(p.join(book.path, 'cover.jpg')).writeAsBytes([4, 5]);
    await File(p.join(book.path, '._01 - Anfang.mp3')).writeAsBytes([0, 0, 0]);
    await File(p.join(book.path, '._cover.jpg')).writeAsBytes([0, 0, 0]);
    final internal = Directory(p.join(root.path, '.library'));
    await internal.create();
    await File(p.join(internal.path, 'index.db')).writeAsBytes([6]);
    final generatedChapters = Directory(
      p.join(root.path, 'Webnovels', 'Titel', '.chapters'),
    );
    await generatedChapters.create(recursive: true);
    await File(
      p.join(generatedChapters.path, 'ch_0001.json'),
    ).writeAsString('{}');
    final synologyMetadata = Directory(
      p.join(book.path, '@eaDir', 'cover.jpg'),
    );
    await synologyMetadata.create(recursive: true);
    await File(
      p.join(synologyMetadata.path, 'SYNOPHOTO_THUMB_XL.jpg'),
    ).writeAsBytes([7]);
    final appleMetadata = Directory(p.join(root.path, '.AppleDouble'));
    await appleMetadata.create();
    await File(p.join(appleMetadata.path, 'metadata')).writeAsBytes([8]);

    final events = await LibraryScanner().scan(root).toList();
    final files = events
        .map((event) => event.file)
        .whereType<ScannedFile>()
        .toList();

    expect(files, hasLength(2));
    expect(files.map((file) => file.filename), isNot(contains('._cover.jpg')));
    expect(
      files.map((file) => file.relativePath),
      contains('Autor/Serie/01 - Titel/01 - Anfang.mp3'),
    );
    expect(files.map((file) => file.mimeType), contains('audio/mpeg'));
    final audio = files.singleWhere((file) => file.extension == 'mp3');
    expect(audio.audioMetadata?.codec, 'MP3');
    expect(audio.audioMetadata?.sampleRateHz, 44100);
    expect(events.last.kind, ScanEventKind.completed);
  });

  test('scanner can be cancelled before traversing files', () async {
    final root = await Directory.systemTemp.createTemp('fundus-cancel-');
    addTearDown(() => root.delete(recursive: true));
    await File(p.join(root.path, 'track.mp3')).writeAsBytes([1]);
    final token = ScanCancellationToken()..cancel();

    final events = await LibraryScanner()
        .scan(root, cancellationToken: token)
        .toList();

    expect(events.last.kind, ScanEventKind.cancelled);
  });

  /// Über eine Netzfreigabe kostet jede Frage einen Weg hin und zurück. Sie
  /// gleichzeitig zu stellen ist der ganze Unterschied zwischen zwei Minuten
  /// und ein paar Sekunden — herauskommen muss dabei dasselbe.
  test('gleichzeitig gefragt kommt heraus, was einzeln herauskommt', () async {
    final root = await Directory.systemTemp.createTemp('fundus-gleichzeitig-');
    addTearDown(() => root.delete(recursive: true));
    for (final album in ['Kraftwerk/Autobahn', 'Kraftwerk/Radio-Aktivität']) {
      final folder = Directory(p.join(root.path, 'Musik', album));
      await folder.create(recursive: true);
      for (var track = 1; track <= 40; track++) {
        await File(
          p.join(folder.path, '${track.toString().padLeft(2, '0')}.mp3'),
        ).writeAsBytes(List.filled(track, 1));
      }
    }

    Future<List<ScannedFile>> walk(int atOnce) async {
      final events = await LibraryScanner(
        filesAtOnce: atOnce,
      ).scan(root).toList();
      expect(events.last.kind, ScanEventKind.completed);
      return events
          .map((event) => event.file)
          .whereType<ScannedFile>()
          .toList();
    }

    final oneByOne = await walk(1);
    final together = await walk(16);

    expect(oneByOne, hasLength(80));
    // Reihenfolge und Inhalt: von der Gleichzeitigkeit ist nichts zu merken.
    expect(
      together.map((file) => file.relativePath),
      oneByOne.map((file) => file.relativePath),
    );
    expect(
      together.map((file) => file.size),
      oneByOne.map((file) => file.size),
    );
    // Und jede Datei genau einmal.
    expect(together.map((file) => file.relativePath).toSet(), hasLength(80));
  });

  test('ein Abbruch zwischen zwei Bündeln hört auf', () async {
    final root = await Directory.systemTemp.createTemp('fundus-abbruch-');
    addTearDown(() => root.delete(recursive: true));
    for (var track = 1; track <= 12; track++) {
      await File(p.join(root.path, '$track.mp3')).writeAsBytes([1]);
    }
    final token = ScanCancellationToken();

    final events = <ScanEvent>[];
    await for (final event in LibraryScanner(
      filesAtOnce: 4,
    ).scan(root, cancellationToken: token)) {
      events.add(event);
      if (events.where((e) => e.kind == ScanEventKind.file).length == 4) {
        token.cancel();
      }
    }

    expect(events.last.kind, ScanEventKind.cancelled);
    expect(events.where((e) => e.kind == ScanEventKind.file), hasLength(4));
  });
}
