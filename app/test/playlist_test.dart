import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/features/lists/list_screen.dart';
import 'package:fundus/features/lists/lists_screen.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

/// Listen: eine Reihe von Werken oder Titeln, die jemand selbst gelegt hat.
///
/// Der Unterschied zwischen Playliste und Leseliste steckt nicht in einem
/// Schalter, sondern in dem, was drinsteht — und die Reihenfolge ist der
/// eigentliche Inhalt einer Liste.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-listen-');
    for (final album in ['Kraftwerk/Autobahn', 'Kraftwerk/Computerwelt']) {
      final folder = Directory('${root.path}/Musik/$album')
        ..createSync(recursive: true);
      for (final track in ['01 Erster.mp3', '02 Zweiter.mp3']) {
        File('${folder.path}/$track').writeAsBytesSync(List.filled(64, 1));
      }
    }
    final manga = Directory('${root.path}/Manga/Klingenwind')
      ..createSync(recursive: true);
    File('${manga.path}/001.cbz').writeAsBytesSync(List.filled(64, 1));
    library = LibraryController();
    settings = AppSettings.inMemory();
    await library.open(root, createIfMissing: true);
    await library.scan();
  });

  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<FundusScopeState> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late FundusScopeState scope;
    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return scope;
  }

  testWidgets('eine Liste entsteht auf der Seite eines Werks', (tester) async {
    final scope = await boot(tester);
    final album = library.works.firstWhere((work) => work.title == 'Autobahn');
    scope.navigation.reset(WorkRoute(album.id));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Zur Liste'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Neue Liste').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Für die Fahrt');
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();

    final list = scope.playlists.single;
    expect(list.name, 'Für die Fahrt');
    expect(list.entries.single.workId, album.id);
    // Von der Werkseite aus meint man das ganze Werk.
    expect(list.entries.single.fileId, isNull);
  });

  testWidgets('eine einzelne Folge landet als Zeile in der Liste', (
    tester,
  ) async {
    final scope = await boot(tester);
    final album = library.works.firstWhere((work) => work.title == 'Autobahn');
    final tracks = library.library!.playbackTracks(album.id);
    scope.createPlaylist('Für die Fahrt');
    await tester.pumpAndSettle();

    scope.addToPlaylist(
      scope.playlists.single.id,
      PlaylistEntry(album.id, fileId: tracks.last.fileId),
    );
    await tester.pumpAndSettle();

    expect(scope.playlists.single.entries.single.fileId, tracks.last.fileId);
  });

  testWidgets('die Liste lässt sich umsortieren und leeren', (tester) async {
    final scope = await boot(tester);
    final works = library.works
        .where((work) => work.kind == 'album')
        .toList(growable: false);
    final list = scope.createPlaylist('Zwei Alben')!;
    for (final work in works) {
      scope.addToPlaylist(list.id, PlaylistEntry(work.id));
    }
    scope.navigation.reset(ListRoute(list.id));
    await tester.pumpAndSettle();

    expect(find.text('Zwei Alben'), findsWidgets);
    expect(find.text(works.first.title), findsOneWidget);

    scope.reorderPlaylist(list.id, 0, 1);
    await tester.pumpAndSettle();
    expect(scope.playlists.single.entries.first.workId, works.last.id);

    await tester.tap(find.byTooltip('Aus der Liste nehmen').first);
    await tester.pumpAndSettle();
    expect(scope.playlists.single.entries.length, 1);
  });

  testWidgets('eine Liste aus Mangas ist eine Leseliste', (tester) async {
    final scope = await boot(tester);
    final manga = library.works.firstWhere(
      (work) => work.title == 'Klingenwind',
    );
    final list = scope.createPlaylist('Vor dem Schlafen')!;
    scope.addToPlaylist(list.id, PlaylistEntry(manga.id));
    await tester.pumpAndSettle();

    expect(isReadingList(scope, scope.playlists.single), isTrue);

    scope.navigation.reset(ListRoute(list.id));
    await tester.pumpAndSettle();
    // Gelesen wird, nicht abgespielt — und Zufall gibt es hier nicht.
    expect(find.text('Weiterlesen'), findsOneWidget);
    expect(find.text('Zufällig'), findsNothing);
  });

  testWidgets('eine Liste aus Alben ist eine Playliste', (tester) async {
    final scope = await boot(tester);
    final album = library.works.firstWhere((work) => work.title == 'Autobahn');
    final list = scope.createPlaylist('Für die Fahrt')!;
    scope.addToPlaylist(list.id, PlaylistEntry(album.id));
    scope.navigation.reset(ListRoute(list.id));
    await tester.pumpAndSettle();

    expect(isReadingList(scope, scope.playlists.single), isFalse);
    expect(find.text('Abspielen'), findsOneWidget);
    expect(find.text('Zufällig'), findsOneWidget);
  });

  testWidgets('ein ganzes Werk bringt alle seine Titel mit', (tester) async {
    final scope = await boot(tester);
    final works = library.works
        .where((work) => work.kind == 'album')
        .toList(growable: false);
    final list = scope.createPlaylist('Zwei Alben')!;
    for (final work in works) {
      scope.addToPlaylist(list.id, PlaylistEntry(work.id));
    }
    await tester.pumpAndSettle();

    final queue = scope.queueFor(scope.playlists.single);
    expect(queue.length, 4);
    // Nur der erste Titel eines Werks macht dort weiter, wo es stand.
    expect(queue.first.resume, isTrue);
    expect(queue[1].resume, isFalse);
    // Und die zweite Zeile fängt hinter den Titeln der ersten an.
    expect(queueStartFor(scope, scope.playlists.single, 1), 2);
  });
}
