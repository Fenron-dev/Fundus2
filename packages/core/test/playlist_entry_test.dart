import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

/// Was in einer Liste steht.
///
/// Eine Playliste ist keine Sammlung von Alben: ein Album ist ein Werk mit
/// einem Dutzend Titeln, und wer eine Liste baut, meint die Titel. Eine
/// Leseliste meint dagegen ganze Werke. Beides muss dieselbe Tabelle können.
void main() {
  late Directory root;
  late FundusLibrary library;
  late List<LibraryWorkSummary> works;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-liste-');
    for (final album in ['Kraftwerk/Autobahn', 'Kraftwerk/Radioaktivität']) {
      final folder = Directory('${root.path}/Musik/$album')
        ..createSync(recursive: true);
      for (final track in ['01 Erster.mp3', '02 Zweiter.mp3']) {
        await File('${folder.path}/$track').writeAsBytes(List.filled(64, 1));
      }
    }
    library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    works = library.listWorks();
  });

  tearDown(() async {
    library.close();
    await root.delete(recursive: true);
  });

  test('eine Zeile darf einen einzelnen Titel meinen', () async {
    final tracks = library.playbackTracks(works.first.id);
    expect(tracks.length, greaterThan(1));

    final list = library.savePlaylist(
      name: 'Für die Fahrt',
      entries: [
        PlaylistEntry(works.first.id, fileId: tracks.last.fileId),
        PlaylistEntry(works.last.id),
      ],
      mediaType: 'album',
    );

    expect(list.entries.first.fileId, tracks.last.fileId);
    // Das ganze Werk bleibt das ganze Werk.
    expect(list.entries.last.fileId, isNull);

    library.close();
    library = await FundusLibrary.open(root);
    final restored = library.listPlaylists().single;
    expect(restored.entries, list.entries);
    // Wer nur Werke kennt, bekommt weiter Werke.
    expect(restored.workIds, [works.first.id, works.last.id]);
  });

  test('zwei Titel desselben Albums sind kein Doppel', () {
    final tracks = library.playbackTracks(works.first.id);
    final list = library.savePlaylist(
      name: 'Ein Album, zwei Titel',
      entries: [
        PlaylistEntry(works.first.id, fileId: tracks.first.fileId),
        PlaylistEntry(works.first.id, fileId: tracks.last.fileId),
      ],
    );

    expect(list.entries.length, 2);
    expect(list.workIds, [works.first.id, works.first.id]);
  });

  test('anhängen, umsortieren, entfernen', () {
    final tracks = library.playbackTracks(works.first.id);
    var list = library.savePlaylist(name: 'Bau', entries: const []);

    list = library.addToPlaylist(
      playlistId: list.id,
      entry: PlaylistEntry(works.first.id, fileId: tracks.first.fileId),
    );
    list = library.addToPlaylist(
      playlistId: list.id,
      entry: PlaylistEntry(works.last.id),
    );
    // Dasselbe noch einmal wächst nicht zu einem zweiten Eintrag.
    list = library.addToPlaylist(
      playlistId: list.id,
      entry: PlaylistEntry(works.last.id),
    );
    expect(list.entries.length, 2);

    list = library.reorderPlaylist(playlistId: list.id, from: 1, to: 0);
    expect(list.entries.first.workId, works.last.id);

    list = library.removeFromPlaylist(playlistId: list.id, index: 0);
    expect(list.entries.single.fileId, tracks.first.fileId);

    // Jede Änderung ist eine neue Fassung — daran erkennt die Gegenstelle,
    // dass sie nachziehen muss.
    expect(list.revision, greaterThan(1));
  });

  test('eine Liste lässt sich umbenennen, ohne sie zu leeren', () {
    var list = library.savePlaylist(
      name: 'Falsch geschrieben',
      entries: [PlaylistEntry(works.first.id)],
    );
    list = library.renamePlaylist(playlistId: list.id, name: 'Richtig');

    expect(list.name, 'Richtig');
    expect(list.entries.single.workId, works.first.id);
  });
}
