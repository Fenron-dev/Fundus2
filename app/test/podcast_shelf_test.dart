import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/media_type.dart';

/// Podcasts have their own shelf.
///
/// They used to be counted as audiobooks, because both are folders full of
/// audio files. Nothing else about them matches, and a shelf of novels with a
/// news podcast between them is a shelf nobody sorted.
void main() {
  late Directory root;
  late LibraryController library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-podcast-');
    final show = Directory('${root.path}/Podcasts/Lage der Nation')
      ..createSync(recursive: true);
    for (final episode in ['LdN 400.mp3', 'LdN 401.mp3']) {
      File('${show.path}/$episode').writeAsBytesSync(List.filled(64, 1));
    }
    final novel = Directory('${root.path}/Hörbücher/Karl May/Der Schacht')
      ..createSync(recursive: true);
    File('${novel.path}/01.mp3').writeAsBytesSync(List.filled(64, 1));
    library = LibraryController();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  test('ein Podcast landet unter Podcasts, nicht unter Hörbüchern', () async {
    await library.open(root, createIfMissing: true);
    await library.scan();

    final show = library.works.firstWhere(
      (work) => work.title.contains('Lage der Nation'),
    );
    expect(show.kind, 'podcast');
    expect(show.mediaType?.id, 'podcast');
    expect(show.mediaType?.label, 'Podcasts');

    final novel = library.works.firstWhere(
      (work) => work.title.contains('Schacht'),
    );
    expect(novel.mediaType?.id, 'audiobook');
  });

  test('die Podcast-Ablage kennt Folgen statt Kapiteln', () {
    final podcasts = MediaTypes.byId('podcast')!;
    expect(podcasts.tabs.first, WorkTab.episodes);
    expect(MediaTypes.audiobook.workKinds, isNot(contains('podcast')));
  });
}
