import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/media/photo_controller.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_design/fundus_design.dart';

/// Looking at pictures.
///
/// The last media type that answered „die Fotoansicht fehlt noch". A gallery
/// is neither a player nor a reader: there is no position to resume, so it
/// keeps none, and an album is a grid until a picture is opened out of it.
void main() {
  late Directory root;
  late FundusLibrary vault;
  late LibraryController library;
  late AppSettings settings;

  /// A one-pixel PNG. Small enough to write a hundred of, real enough to
  /// decode.
  final png = <int>[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
    0x42, 0x60, 0x82,
  ];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-photos-');
    final album = Directory('${root.path}/Fotos/Island 2025');
    await album.create(recursive: true);
    for (final name in ['01.jpg', '02.png', '03.webp', 'notizen.txt']) {
      await File('${album.path}/$name').writeAsBytes(png);
    }
    vault = await FundusLibrary.create(root);
    await for (final _ in vault.index()) {}

    library = LibraryController();
    settings = AppSettings.inMemory();
    await library.open(root);
  });

  tearDown(() async {
    library.dispose();
    vault.close();
    await root.delete(recursive: true);
  });

  test('nur Bilder kommen ins Album, keine Notizen', () async {
    final photos = PhotoController();
    addTearDown(photos.dispose);
    final work = library.works.single;

    await photos.open(library.library!, work);

    expect(photos.failure, isNull);
    expect(photos.pictures.map((picture) => picture.title), [
      '01.jpg',
      '02.png',
      '03.webp',
    ]);
  });

  test('ein Album ist erst ein Raster, dann ein Bild', () async {
    final photos = PhotoController();
    addTearDown(photos.dispose);
    await photos.open(library.library!, library.works.single);

    // Raster: noch kein Bild geöffnet.
    expect(photos.index, isNull);

    photos.show(1);
    expect(photos.index, 1);
    photos.next();
    expect(photos.index, 2);
    // Über das Ende hinaus passiert nichts.
    photos.next();
    expect(photos.index, 2);

    photos.closePicture();
    expect(photos.index, isNull);
    expect(photos.isOpen, isTrue);
  });

  testWidgets('ein Fotowerk öffnet die Ansicht statt sie zu vermissen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
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
    // Ohne geöffnete Route zeigt die Shell die Bibliotheksauswahl und baut
    // die Überlagerungen gar nicht erst.
    scope.navigation.reset(const DashboardRoute());
    await tester.pumpAndSettle();

    await tester.runAsync(() => scope.play(library.works.single));
    await tester.pumpAndSettle();

    // Vorher stand hier „Die Fotoansicht fehlt noch".
    expect(find.textContaining('fehlt noch'), findsNothing);
    expect(scope.photos.isOpen, isTrue);
    expect(scope.photos.pictures, hasLength(3));
    expect(find.text('3 Bilder'), findsOneWidget);
  });
}
