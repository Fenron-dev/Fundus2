import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/data/sync_controller.dart';
import 'package:fundus/media/reader_controller.dart';
import 'package:fundus_design/fundus_design.dart';

import 'reader_test.dart' show FakePageSource, writeArchive;

/// Ein Lesestand, der das Gerät verlässt, bevor jemand etwas schließt.
///
/// Auf dem Handy bleibt der Leser offen, wenn man zum Rechner wechselt. Solange
/// der Stand erst beim Schließen loszog, zog er nie los — der Weg Mac → Handy
/// funktionierte, Handy → Mac nicht.
final class RecordingSync extends SyncController {
  RecordingSync({required super.settings, required super.library})
    : super(connect: _never);

  final List<String> pushed = [];

  static Never _never(Object? peer) =>
      throw StateError('darf nicht verbunden werden');

  @override
  Future<void> pushWork(String workId) async => pushed.add(workId);
}

void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late ReaderController reader;
  late RecordingSync sync;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-push-');
    final work = Directory('${root.path}/Manga/Klingenwind')
      ..createSync(recursive: true);
    writeArchive(work, 'Kapitel 01.cbz', ['001.jpg', '002.jpg']);
    library = LibraryController();
    settings = AppSettings.inMemory();
    reader = ReaderController(
      openSource: (path, name) => FakePageSource(name, 12),
    );
    sync = RecordingSync(settings: settings, library: library);
  });

  tearDown(() async {
    reader.dispose();
    sync.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  testWidgets('das Weglegen schickt den Lesestand los', (tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
    });

    late FundusScopeState scope;
    await tester.pumpWidget(
      MaterialApp(
        theme: FundusTheme.dark(),
        home: FundusScope(
          settings: settings,
          library: library,
          reader: reader,
          sync: sync,
          child: Builder(
            builder: (context) {
              scope = FundusScope.of(context);
              return const FundusShell();
            },
          ),
        ),
      ),
    );
    scope.navigation.reset(WorkRoute(library.works.first.id));
    await tester.pumpAndSettle();
    await tester.runAsync(() => scope.play(library.works.first));
    await tester.pumpAndSettle();
    expect(reader.isOpen, isTrue);
    // Das Senden ist entprellt, und der Zeitgeber läuft in echter Zeit —
    // hier wird er abgewartet, damit das Öffnen den Zähler nicht verfälscht.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2500)),
    );
    sync.pushed.clear();

    // Zum anderen Gerät wechseln, ohne etwas zu schließen. Der
    // Zustandsautomat lässt keinen Sprung zu: erst inaktiv, dann weg.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Dieser Zeitgeber entsteht in der Testuhr, also wird sie vorgestellt.
    await tester.pump(const Duration(seconds: 3));

    expect(sync.pushed, [library.works.first.id]);
  });
}
