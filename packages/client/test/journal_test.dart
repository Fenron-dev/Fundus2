import 'dart:io';

import 'package:fundus_client/fundus_client.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

/// What the sync decided, and why it could tell.
///
/// Comparing two positions says which is further along; it never says which
/// one *moved*. The third point — what both sides agreed on last time — is
/// what turns „one of these is newer" into „both of these changed", and that
/// is the only case worth calling a conflict.
void main() {
  late Directory temporary;
  late FundusLibrary mine;
  late FundusLibrary theirs;
  late FundusLibraryRegistry registry;
  late HttpServer socket;
  late FundusRemoteClient client;
  late String workId;
  late String fileId;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-journal-');
    final source = Directory('${temporary.path}/meine');
    final work = Directory('${source.path}/Hörbücher/Karl May/Der Schacht');
    await work.create(recursive: true);
    await File('${work.path}/01 - Anfang.mp3').writeAsBytes(List.filled(64, 1));
    mine = await FundusLibrary.create(source);
    await for (final _ in mine.index()) {}
    workId = mine.listWorks().single.id;
    fileId = mine.playbackTracks(workId).single.fileId;

    final copy = Directory('${temporary.path}/ihre');
    await copy.create(recursive: true);
    await for (final entity in source.list(recursive: true)) {
      final relative = entity.path.substring(source.path.length + 1);
      if (entity is Directory) {
        await Directory('${copy.path}/$relative').create(recursive: true);
      } else if (entity is File) {
        final target = File('${copy.path}/$relative');
        await target.parent.create(recursive: true);
        await entity.copy(target.path);
      }
    }
    theirs = await FundusLibrary.open(copy);

    registry = FundusLibraryRegistry()..register(theirs, name: 'Hörbücher');
    socket = await shelf_io.serve(
      FundusServerHandler(
        token: 'geheim',
        serverId: 'server-test',
        registry: registry,
      ).handler,
      'localhost',
      0,
    );
    client = FundusRemoteClient(
      baseUri: Uri.parse('http://localhost:${socket.port}'),
      token: 'geheim',
    );
  });

  tearDown(() async {
    client.close();
    await socket.close(force: true);
    registry.close();
    mine.close();
    await temporary.delete(recursive: true);
  });

  FundusSync syncer([SyncBaseline baseline = const SyncBaseline({})]) =>
      FundusSync(
        library: mine,
        client: client,
        libraryId: theirs.manifest.libraryId,
        deviceId: 'mein-geraet',
        baseline: baseline,
      );

  void hereAt(Duration position) => mine.saveProgress(
    workId: workId,
    fileId: fileId,
    position: position,
    deviceId: 'mein-geraet',
  );

  void thereAt(Duration position) => theirs.saveProgress(
    workId: workId,
    fileId: fileId,
    position: position,
    deviceId: 'anderes-geraet',
  );

  test('das Journal nennt Werk, Entscheidung und beide Stände', () async {
    hereAt(const Duration(minutes: 12));

    final report = await syncer().run();

    expect(report.entries, hasLength(1));
    final entry = report.entries.single;
    expect(entry.workId, workId);
    expect(entry.title, 'Der Schacht');
    expect(entry.decision, SyncDecision.pushed);
    // In Worten, nicht in Sekunden: „12 min" kann man abwägen.
    expect(entry.mine, '12 min');
  });

  test('nur eine Seite bewegt sich — kein Konflikt', () async {
    hereAt(const Duration(minutes: 12));
    final first = await syncer().run();
    final baseline = SyncBaseline(first.agreedMarks);

    // Drüben wird weitergehört, hier nicht.
    thereAt(const Duration(minutes: 30));
    final second = await syncer(baseline).run();

    expect(second.conflicts, isEmpty);
    expect(second.entries.single.decision, SyncDecision.pulled);
    expect(
      mine.loadProgress(workId)!.position.numericValue,
      closeTo(30 * 60, 0.001),
    );
  });

  test(
    'beide bewegt — das ist ein Konflikt, und er steht im Journal',
    () async {
      hereAt(const Duration(minutes: 12));
      final first = await syncer().run();
      final baseline = SyncBaseline(first.agreedMarks);

      // Beide Seiten hören weiter, ohne voneinander zu wissen.
      thereAt(const Duration(minutes: 40));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      hereAt(const Duration(minutes: 20));

      final report = await syncer(baseline).run();

      expect(report.conflicts, hasLength(1));
      final conflict = report.conflicts.single;
      expect(conflict.decision, SyncDecision.conflict);
      // Beide Stände stehen dort, damit man sie gegeneinander halten kann.
      expect(conflict.mine, '20 min');
      expect(conflict.theirs, '40 min');
      // Entschieden wird trotzdem — der spätere Schreibvorgang.
      expect(conflict.note, contains('von hier'));
      expect(
        theirs.loadProgress(workId)!.position.numericValue,
        closeTo(20 * 60, 0.001),
      );
    },
  );

  test('ohne Grundlinie wird nichts als Konflikt ausgegeben', () async {
    // Das erste Treffen zweier Geräte: es gibt keinen dritten Punkt, also
    // auch nichts, was man Konflikt nennen dürfte.
    thereAt(const Duration(minutes: 40));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    hereAt(const Duration(minutes: 12));

    final report = await syncer().run();

    expect(report.conflicts, isEmpty);
    expect(report.entries.single.decision, SyncDecision.pushed);
  });

  test('nach dem Abgleich ist die Grundlinie der gemeinsame Stand', () async {
    hereAt(const Duration(minutes: 12));
    final first = await syncer().run();

    // Ein zweiter Lauf auf derselben Grundlinie hat nichts zu tun.
    final second = await syncer(SyncBaseline(first.agreedMarks)).run();

    expect(second.changedAnything, isFalse);
    expect(second.conflicts, isEmpty);
  });
}
