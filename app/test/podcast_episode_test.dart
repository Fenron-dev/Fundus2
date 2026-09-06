import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/app/app_navigation.dart';
import 'package:fundus/app/app_settings.dart';
import 'package:fundus/app/fundus_scope.dart';
import 'package:fundus/app/shell/fundus_shell.dart';
import 'package:fundus/data/library_controller.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/metadata/metadata_apply.dart';
import 'package:fundus_design/fundus_design.dart';

import 'playback_controller_test.dart' show FakeEngine;

/// Die Folgenliste einer Sendung.
///
/// Ein Tipp auf die Zeile führt zu dem, worum es in der Folge geht — nicht
/// zum Start. Gestartet wird mit dem Knopf davor, und die Marken innerhalb
/// der Folge sind das, wonach man in einem zweistündigen Gespräch sucht.
void main() {
  late Directory root;
  late LibraryController library;
  late AppSettings settings;
  late FakeEngine engine;
  late PlaybackController player;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-folge-');
    final show = Directory('${root.path}/Podcasts/Auf ein Bier')
      ..createSync(recursive: true);
    await File('${show.path}/Auf ein Bier 564.mp3').writeAsBytes(
      _mp3([
        _text('TIT2', 'Auf ein Bier #564'),
        _comment('Tolle Dinge, die wir nicht toll finden.'),
        _chapter('c1', 0, 'Begrüßung'),
        _chapter('c2', 900000, 'Das Spiel'),
      ]),
    );
    await File(
      '${show.path}/Hardware-Talk.mp3',
    ).writeAsBytes(_mp3([_text('TIT2', 'Hardware-Talk')]));
    library = LibraryController();
    settings = AppSettings.inMemory();
    engine = FakeEngine();
    player = PlaybackController(engine: engine);
  });

  tearDown(() async {
    player.dispose();
    library.dispose();
    await root.delete(recursive: true);
  });

  Future<FundusScopeState> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await library.open(root, createIfMissing: true);
      await library.scan();
      // Im Betrieb liest die Folgenliste die Texte selbst nach; in einem
      // Widget-Test läuft echte Ein- und Ausgabe nur in diesem Fenster.
      await describeFromTags(
        library: library.library!,
        workId: library.works.single.id,
      );
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
    return scope;
  }

  testWidgets('ein Tipp auf die Zeile zeigt die Folge, statt sie zu starten', (
    tester,
  ) async {
    await pump(tester);

    await tester.runAsync(() async {
      await tester.tap(find.textContaining('Auf ein Bier #564'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();

    expect(
      find.text('Tolle Dinge, die wir nicht toll finden.'),
      findsOneWidget,
    );
    // Und nichts läuft: der Text war die Frage, nicht der Start.
    expect(player.work, isNull);
  });

  testWidgets('der Knopf davor startet die Folge', (tester) async {
    await pump(tester);

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Abspielen').first);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();

    expect(player.currentSource?.title, contains('Auf ein Bier'));
  });

  testWidgets('eine Kapitelmarke startet an ihrer Stelle', (tester) async {
    await pump(tester);

    await tester.runAsync(() async {
      await tester.tap(find.textContaining('Auf ein Bier #564'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pumpAndSettle();

    expect(find.text('Das Spiel'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Das Spiel'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pumpAndSettle();

    expect(engine.starts.last, const Duration(minutes: 15));
  });
}

List<int> _mp3(List<List<int>> frames) {
  final body = [for (final frame in frames) ...frame];
  return [
    ...ascii.encode('ID3'),
    3,
    0,
    0,
    (body.length >> 21) & 0x7f,
    (body.length >> 14) & 0x7f,
    (body.length >> 7) & 0x7f,
    body.length & 0x7f,
    ...body,
  ];
}

List<int> _text(String id, String value) =>
    _frame(id, [0, ...latin1.encode(value)]);

List<int> _comment(String value) =>
    _frame('COMM', [0, ...ascii.encode('deu'), 0, ...latin1.encode(value)]);

List<int> _chapter(String id, int startMs, String title) => _frame('CHAP', [
  ...latin1.encode(id),
  0,
  ..._uint32(startMs),
  ..._uint32(startMs + 60000),
  ..._uint32(0xffffffff),
  ..._uint32(0xffffffff),
  ..._frame('TIT2', [0, ...latin1.encode(title)]),
]);

List<int> _frame(String id, List<int> payload) => [
  ...ascii.encode(id),
  ..._uint32(payload.length),
  0,
  0,
  ...payload,
];

List<int> _uint32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];
