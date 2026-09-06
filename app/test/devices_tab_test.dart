import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus_design/fundus_design.dart';

import 'playback_controller_test.dart' show FakeEngine;

/// Der Geräte-Reiter.
///
/// Er zählte Geräte auf. Gefragt ist aber, wo jedes von ihnen in *diesem*
/// Werk steht — und ob man den Stand von drüben hierher holen will.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late PlaybackController player;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-geraete-');
    final show = Directory('${root.path}/Serien/Aschegarten')
      ..createSync(recursive: true);
    for (final name in ['S02E03 - Rückkanal', 'S02E04 - Zwölf Stunden']) {
      File('${show.path}/$name.mkv').writeAsBytesSync(List.filled(64, 1));
    }
    library = LibraryController();
    settings = AppSettings.inMemory();
    player = PlaybackController(engine: FakeEngine());
  });

  tearDown(() async {
    player.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('der Reiter zeigt den Stand dieses Geräts', (tester) async {
    tester.view.physicalSize = const Size(1100, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      final vault = library.library!;
      final work = vault.listWorks().single;
      vault.saveProgress(
        workId: work.id,
        fileId: vault.playbackTracks(work.id).first.fileId,
        position: const Duration(minutes: 27, seconds: 10),
        duration: const Duration(minutes: 51),
        deviceId: 'dieses-geraet',
      );
      library.refresh();
    });

    late FundusScopeState scope;
    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          player: player,
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    scope.navigation.reset(WorkRoute(library.works.single.id));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Geräte'));
    await tester.pumpAndSettle();

    expect(find.text('STAND PRO GERÄT'), findsOneWidget);
    expect(find.textContaining('dieses Gerät'), findsOneWidget);
    // Und die Stelle, an der es steht — nicht nur, dass es das Gerät gibt.
    expect(find.textContaining('27:10'), findsOneWidget);
    // Ohne zweites Gerät sagt die Seite, warum sonst nichts dasteht.
    expect(find.textContaining('mit keinem anderen gekoppelt'), findsOneWidget);
  });
}
