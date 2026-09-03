import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/data/work_view.dart';
import 'package:fundus/media/playback_controller.dart';
import 'package:fundus/media/playback_engine.dart';
import 'package:fundus_core/fundus_core.dart';

/// A stand-in for libmpv: it records what the controller asked for and lets a
/// test push positions back, which is exactly the surface the rules need.
final class FakeEngine implements PlaybackEngine {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  final List<Uri> opened = [];
  final List<Duration> starts = [];
  final List<Duration> seeks = [];
  double rate = 1;
  bool playing = false;
  bool stopped = false;
  bool disposed = false;

  void emitPosition(Duration value) => _position.add(value);
  void emitDuration(Duration value) => _duration.add(value);
  void emitCompleted() => _completed.add(true);

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<bool> get completedStream => _completed.stream;

  @override
  Future<void> open(Uri uri, {Duration start = Duration.zero}) async {
    opened.add(uri);
    starts.add(start);
  }

  @override
  Widget? videoSurface() => null;

  @override
  Future<void> play() async {
    playing = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    playing = false;
    _playing.add(false);
  }

  @override
  Future<void> stop() async {
    stopped = true;
    playing = false;
  }

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> setRate(double value) async => rate = value;

  @override
  Future<void> dispose() async {
    disposed = true;
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _completed.close();
  }
}

/// Builds a vault with one audiobook of two tracks.
Future<(FundusLibrary, WorkView)> buildLibrary(Directory root) async {
  final work = Directory('${root.path}/Karl May/Der Schacht')
    ..createSync(recursive: true);
  await File('${work.path}/01 - Anfang.mp3').writeAsBytes(List.filled(64, 1));
  await File('${work.path}/02 - Mitte.mp3').writeAsBytes(List.filled(64, 2));

  final library = await FundusLibrary.create(root);
  await library.index().drain<void>();
  final summary = library.listWorks().firstWhere(
    (entry) => entry.fileCount > 0,
  );
  return (library, WorkView.fromSummary(summary));
}

void main() {
  late Directory root;
  late FundusLibrary library;
  late WorkView work;
  late FakeEngine engine;
  late PlaybackController controller;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fundus-player-');
    (library, work) = await buildLibrary(root);
    engine = FakeEngine();
    controller = PlaybackController(engine: engine, deviceId: 'test-device');
  });

  tearDown(() async {
    controller.dispose();
    library.close();
    await root.delete(recursive: true);
  });

  test('öffnen lädt die erste Datei und spielt', () async {
    await controller.open(library, work);

    expect(controller.failure, isNull);
    expect(controller.sources, hasLength(2));
    expect(engine.opened, hasLength(1));
    expect(engine.playing, isTrue);
  });

  test('der Fortschritt landet in der Bibliothek und kommt zurück', () async {
    await controller.open(library, work);
    engine.emitDuration(const Duration(minutes: 40));
    engine.emitPosition(const Duration(minutes: 12));
    await Future<void>.delayed(Duration.zero);

    controller.saveProgress();

    final stored = library.loadProgress(work.id);
    expect(stored, isNotNull);
    expect(stored!.position.numericValue, closeTo(720, 1));

    // Ein zweites Öffnen setzt genau dort wieder an.
    final resumeEngine = FakeEngine();
    final resumed = PlaybackController(engine: resumeEngine);
    addTearDown(resumed.dispose);
    await resumed.open(library, work, autoplay: false);
    expect(resumed.position, const Duration(minutes: 12));
    // Entscheidend: die Stelle geht in das Öffnen ein. Ein Sprung danach
    // verpufft, solange die Datei noch lädt — genau so ging der Hörstand
    // bisher verloren.
    expect(resumeEngine.starts.single, const Duration(minutes: 12));
  });

  test('Pause schreibt den Stand sofort', () async {
    await controller.open(library, work);
    engine.emitPosition(const Duration(minutes: 3));
    await Future<void>.delayed(Duration.zero);

    await controller.playOrPause();
    await Future<void>.delayed(Duration.zero);

    expect(library.loadProgress(work.id), isNotNull);
  });

  test('das Ende einer Datei geht zur nächsten', () async {
    await controller.open(library, work);
    expect(controller.trackIndex, 0);

    engine.emitCompleted();
    // Der Wechsel prüft die Datei auf der Platte — das ist echte Arbeit.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(controller.trackIndex, 1);
    expect(engine.opened, hasLength(2));
  });

  test('zurück springt erst an den Dateianfang', () async {
    await controller.open(library, work);
    engine.emitPosition(const Duration(seconds: 30));
    await Future<void>.delayed(Duration.zero);

    await controller.previous();

    expect(engine.seeks.last, Duration.zero);
    expect(controller.trackIndex, 0);
  });

  test('die Geschwindigkeit läuft im Kreis', () async {
    await controller.open(library, work);

    await controller.cycleRate();
    expect(controller.rate, 1.25);
    expect(engine.rate, 1.25);
  });

  test('eine fehlende Datei ist ein Zustand, kein Absturz', () async {
    await controller.open(library, work);
    final path = Uri.parse(engine.opened.first.toString()).toFilePath();
    await File(path).delete();

    final second = PlaybackController(engine: FakeEngine());
    addTearDown(second.dispose);
    await second.open(library, work);

    expect(second.failure, contains('nicht erreichbar'));
    expect(second.work, isNotNull);
  });

  test('ohne abspielbare Dateien sagt der Player das', () async {
    final empty = WorkView.fromSummary(
      LibraryWorkSummary(
        id: 'unbekannt',
        kind: 'audiobook',
        title: 'Nichts',
        author: 'Niemand',
        fileCount: 0,
        addedAt: DateTime(2026),
      ),
    );

    await controller.open(library, empty);

    expect(controller.failure, contains('keine abspielbaren'));
  });

  test(
    'ein gestarteter Titel öffnet den Player, nicht den Randstreifen',
    () async {
      await controller.open(library, work);

      expect(controller.isExpanded, isTrue);

      controller.collapse();
      expect(controller.isExpanded, isFalse);
    },
  );

  test('ohne Wiedergabe bleibt der Player zu', () async {
    await controller.open(library, work, autoplay: false);

    expect(controller.isExpanded, isFalse);
  });
}
